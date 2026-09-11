// ignore_for_file: inference_failure_on_function_invocation

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:ai_buddy/core/logger/logger.dart';
import 'package:ai_buddy/core/util/secure_storage.dart';
import 'package:ai_buddy/feature/gemini/gemini.dart';
import 'package:ai_buddy/feature/gemini/repository/base_gemini_repository.dart';
import 'package:dio/dio.dart';

class GeminiRepository extends BaseGeminiRepository {
  GeminiRepository();

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  static const baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  // Cached active model name to prevent 404s
  static String? _resolvedModel;

  /// Dynamically queries the Google Generative Language API to find an active
  /// model supporting generateContent for the given API key.
  Future<String> resolveActiveModel(String apiKey) async {
    if (_resolvedModel != null) return _resolvedModel!;

    try {
      final res = await dio.get<Map<String, dynamic>>(
        'https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey',
        options: Options(
          responseType: ResponseType.json,
          headers: {'Content-Type': 'application/json'},
        ),
      );
      final modelsList = res.data?['models'] as List?;
      if (modelsList != null && modelsList.isNotEmpty) {
        // Look for modern Flash models first
        for (final m in modelsList) {
          if (m is Map) {
            final name = m['name']?.toString() ?? '';
            final methods = (m['supportedGenerationMethods'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                [];
            if (methods.contains('generateContent') &&
                name.toLowerCase().contains('flash')) {
              _resolvedModel = name.replaceFirst('models/', '');
              logInfo('Resolved active Gemini Flash model: $_resolvedModel');
              return _resolvedModel!;
            }
          }
        }
        // Fallback: any model supporting generateContent
        for (final m in modelsList) {
          if (m is Map) {
            final name = m['name']?.toString() ?? '';
            final methods = (m['supportedGenerationMethods'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                [];
            if (methods.contains('generateContent')) {
              _resolvedModel = name.replaceFirst('models/', '');
              logInfo('Resolved active Gemini model: $_resolvedModel');
              return _resolvedModel!;
            }
          }
        }
      }
    } catch (e) {
      logError('Could not dynamically list models: $e');
    }

    // Default to gemini-2.0-flash if model list is unreachable
    _resolvedModel = 'gemini-2.0-flash';
    return _resolvedModel!;
  }

  /// Streams content from the Gemini API using Server-Sent Events (SSE)
  /// or robust JSON chunk parsing. Supports multi-turn conversations,
  /// images, and PDF documents.
  @override
  Stream<Candidates> streamContent({
    Content? content,
    List<Map<String, dynamic>>? contents,
    Uint8List? image,
    String? imageMimeType,
    Uint8List? document,
    String? documentMimeType,
    String? model,
  }) async* {
    final geminiAPIKey = await SecureStorage().getApiKey();
    if (geminiAPIKey == null || geminiAPIKey.trim().isEmpty) {
      throw Exception(
        'Gemini API key is not set. Please add your API key in Settings.',
      );
    }

    final apiKey = geminiAPIKey.trim();
    String targetModel = model ?? await resolveActiveModel(apiKey);

    // Build the contents list
    final List<Map<String, dynamic>> apiContents = [];

    if (contents != null && contents.isNotEmpty) {
      for (final item in contents) {
        apiContents.add(Map<String, dynamic>.from(item));
      }
    } else if (content != null) {
      final partsList = <Map<String, dynamic>>[];
      if (content.parts != null) {
        for (final p in content.parts!) {
          if (p.text != null && p.text!.isNotEmpty) {
            partsList.add({'text': p.text});
          }
        }
      }
      apiContents.add({
        'role': content.role ?? 'user',
        'parts': partsList,
      });
    }

    // Ensure there is at least one message
    if (apiContents.isEmpty) {
      apiContents.add({
        'role': 'user',
        'parts': [
          {'text': 'Hello'}
        ],
      });
    }

    // Attach document (e.g. PDF) if provided
    if (document != null && document.isNotEmpty) {
      final docPart = {
        'inlineData': {
          'mimeType': documentMimeType ?? 'application/pdf',
          'data': base64Encode(document),
        },
      };

      final userIndex = apiContents.lastIndexWhere((c) => c['role'] == 'user');
      if (userIndex != -1) {
        final existingParts = ((apiContents[userIndex]['parts'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        apiContents[userIndex]['parts'] = [docPart, ...existingParts];
      } else {
        apiContents.insert(0, {
          'role': 'user',
          'parts': [docPart],
        });
      }
    }

    // Attach image if provided
    if (image != null && image.isNotEmpty) {
      final imagePart = {
        'inlineData': {
          'mimeType': imageMimeType ?? 'image/jpeg',
          'data': base64Encode(image),
        },
      };

      final userIndex = apiContents.lastIndexWhere((c) => c['role'] == 'user');
      if (userIndex != -1) {
        final existingParts = ((apiContents[userIndex]['parts'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        apiContents[userIndex]['parts'] = [...existingParts, imagePart];
      } else {
        apiContents.add({
          'role': 'user',
          'parts': [imagePart],
        });
      }
    }

    final Map<String, dynamic> requestPayload = {
      'contents': apiContents,
      'generationConfig': {
        'temperature': 0.7,
        'maxOutputTokens': 2048,
      },
      'safetySettings': [
        {
          'category': 'HARM_CATEGORY_DANGEROUS_CONTENT',
          'threshold': 'BLOCK_ONLY_HIGH',
        },
        {
          'category': 'HARM_CATEGORY_HARASSMENT',
          'threshold': 'BLOCK_ONLY_HIGH',
        },
        {
          'category': 'HARM_CATEGORY_HATE_SPEECH',
          'threshold': 'BLOCK_ONLY_HIGH',
        },
        {
          'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT',
          'threshold': 'BLOCK_ONLY_HIGH',
        },
      ],
    };

    Response<ResponseBody>? response;

    // List of model fallbacks in case targetModel returns 404
    final candidateModels = [
      targetModel,
      'gemini-2.0-flash',
      'gemini-2.5-flash',
      'gemini-1.5-flash-latest',
      'gemini-pro',
    ];

    DioException? lastDioException;

    for (final candidate in candidateModels.toSet()) {
      final url =
          '$baseUrl/$candidate:streamGenerateContent?alt=sse&key=$apiKey';
      try {
        response = await dio.post<ResponseBody>(
          url,
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'text/event-stream',
            },
            responseType: ResponseType.stream,
          ),
          data: jsonEncode(requestPayload),
        );
        _resolvedModel = candidate;
        break; // Successfully connected!
      } on DioException catch (dioErr) {
        lastDioException = dioErr;
        if (dioErr.response?.statusCode == 404) {
          logError('Model $candidate returned 404. Trying next candidate...');
          _resolvedModel = null;
          continue; // try next candidate model
        } else {
          // Other error (400, 403, 429), rethrow immediately
          final errorMsg = await _extractDioErrorMessage(dioErr);
          logError('DioException in streamContent: $errorMsg');
          throw Exception(errorMsg);
        }
      } catch (e) {
        logError('Network error in streamContent: $e');
        throw Exception('Connection failed: $e');
      }
    }

    if (response == null || response.statusCode != 200) {
      if (lastDioException != null) {
        final errorMsg = await _extractDioErrorMessage(lastDioException);
        throw Exception(errorMsg);
      }
      throw Exception('Failed to connect to Gemini API.');
    }

    final ResponseBody rb = response.data!;
    final stream = rb.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    String buffer = '';

    await for (final line in stream) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith(':')) {
        continue;
      }

      String chunk = trimmed;
      if (chunk.startsWith('data:')) {
        chunk = chunk.substring(5).trim();
      }

      if (chunk == '[DONE]') {
        break;
      }

      // If streaming as JSON array, clean array brackets
      if (buffer.isEmpty) {
        if (chunk.startsWith('[')) chunk = chunk.substring(1).trim();
        if (chunk.startsWith(',')) chunk = chunk.substring(1).trim();
      }

      if (chunk.isEmpty) continue;

      buffer = buffer.isEmpty ? chunk : '$buffer\n$chunk';

      String candidateJson = buffer.trim();
      if (candidateJson.endsWith(']')) {
        candidateJson =
            candidateJson.substring(0, candidateJson.length - 1).trim();
      }

      try {
        final decoded = jsonDecode(candidateJson);
        buffer = ''; // successfully decoded full JSON object

        if (decoded is Map<String, dynamic>) {
          if (decoded.containsKey('error')) {
            final errorMap = decoded['error'] as Map<String, dynamic>?;
            final message = errorMap?['message']?.toString() ??
                'Gemini API returned an error';
            throw Exception(message);
          }

          final candidatesList = decoded['candidates'] as List?;
          if (candidatesList != null && candidatesList.isNotEmpty) {
            final firstCandidate = candidatesList.first;
            if (firstCandidate is Map<String, dynamic>) {
              final candidate = Candidates.fromJson(firstCandidate);
              yield candidate;
            }
          }
        }
      } catch (e) {
        if (e is Exception && e.toString().contains('Gemini API returned')) {
          rethrow;
        }
        // Incomplete JSON chunk, buffer continues accumulating
      }
    }
  }

  /// Extracts user-friendly error message from DioException
  Future<String> _extractDioErrorMessage(DioException dioErr) async {
    if (dioErr.response?.data != null) {
      try {
        final data = dioErr.response!.data;
        if (data is Map && data.containsKey('error')) {
          return data['error']['message']?.toString() ??
              'API error (${dioErr.response?.statusCode})';
        }
        if (data is ResponseBody) {
          final errorBytes = await data.stream.toList();
          final flatBytes = errorBytes.expand((i) => i).toList();
          final errorString = utf8.decode(flatBytes);
          final decoded = jsonDecode(errorString);
          if (decoded is Map && decoded.containsKey('error')) {
            final errorObj = decoded['error'];
            if (errorObj is Map && errorObj.containsKey('message')) {
              return errorObj['message'].toString();
            }
          }
        }
        if (data is String) {
          final decoded = jsonDecode(data);
          if (decoded is Map && decoded.containsKey('error')) {
            return decoded['error']['message']?.toString() ?? data;
          }
        }
      } catch (_) {}
    }

    if (dioErr.type == DioExceptionType.connectionTimeout ||
        dioErr.type == DioExceptionType.receiveTimeout) {
      return 'Connection timed out. Please check your internet connection.';
    }

    if (dioErr.response?.statusCode == 400) {
      return 'Invalid request or API key. Please verify your Gemini API key in Settings.';
    }
    if (dioErr.response?.statusCode == 403) {
      return 'Permission denied. Make sure your API key has access to the Gemini API.';
    }
    if (dioErr.response?.statusCode == 404) {
      return 'Model not found. Please check model availability for your API key.';
    }
    if (dioErr.response?.statusCode == 429) {
      return 'Gemini API quota exceeded. Please wait a moment or check your billing plan.';
    }

    return dioErr.message ?? 'Network error occurred.';
  }

  /// Processes a batch of text chunks to generate embeddings (kept for legacy support).
  @override
  Future<Map<String, List<num>>> batchEmbedChunks({
    required List<String> textChunks,
  }) async {
    try {
      final geminiAPIKey = await SecureStorage().getApiKey();
      if (geminiAPIKey == null || geminiAPIKey.trim().isEmpty) {
        throw Exception('Gemini API key is not set.');
      }
      final Map<String, List<num>> embeddingsMap = {};
      const int chunkSize = 50;

      for (int i = 0; i < textChunks.length; i += chunkSize) {
        final chunkEnd = (i + chunkSize < textChunks.length)
            ? i + chunkSize
            : textChunks.length;
        final List<String> currentChunk = textChunks.sublist(i, chunkEnd);
        final response = await dio.post(
          '$baseUrl/text-embedding-004:batchEmbedContents?key=${geminiAPIKey.trim()}',
          options: Options(headers: {'Content-Type': 'application/json'}),
          data: {
            'requests': currentChunk
                .map(
                  (text) => {
                    'model': 'models/text-embedding-004',
                    'content': {
                      'parts': [
                        {'text': text},
                      ],
                    },
                    'taskType': 'RETRIEVAL_DOCUMENT',
                  },
                )
                .toList(),
          },
        );
        final results = response.data['embeddings'] as List?;
        if (results != null) {
          for (var j = 0; j < currentChunk.length; j++) {
            if (j < results.length && results[j]['values'] != null) {
              embeddingsMap[currentChunk[j]] =
                  (results[j]['values'] as List).cast<num>();
            }
          }
        }
      }
      return embeddingsMap;
    } catch (e) {
      logError('Error in batchEmbedChunks: $e');
      rethrow;
    }
  }

  /// Generates a prompt for embedding based on the user's input and
  /// the pre-calculated embeddings (legacy RAG fallback).
  @override
  Future<String> promptForEmbedding({
    required String userPrompt,
    required Map<String, List<num>>? embeddings,
  }) async {
    try {
      final geminiAPIKey = await SecureStorage().getApiKey();
      if (geminiAPIKey == null || geminiAPIKey.trim().isEmpty) {
        return userPrompt;
      }
      final response = await dio.post(
        '$baseUrl/text-embedding-004:embedContent?key=${geminiAPIKey.trim()}',
        options: Options(headers: {'Content-Type': 'application/json'}),
        data: jsonEncode({
          'model': 'models/text-embedding-004',
          'content': {
            'parts': [
              {'text': userPrompt},
            ],
          },
          'taskType': 'RETRIEVAL_QUERY',
        }),
      );
      final currentEmbedding =
          (response.data['embedding']['values'] as List).cast<num>();
      if (embeddings == null || embeddings.isEmpty) {
        return userPrompt;
      }

      final Map<String, double> distances = {};
      embeddings.forEach((key, value) {
        if (value.length == currentEmbedding.length) {
          final double distance = calculateEuclideanDistance(
            vectorA: currentEmbedding,
            vectorB: value,
          );
          distances[key] = distance;
        }
      });

      if (distances.isEmpty) return userPrompt;

      final List<MapEntry<String, double>> sortedDistances = distances.entries
          .toList()
        ..sort((a, b) => a.value.compareTo(b.value));

      final StringBuffer mergedText = StringBuffer();
      for (int i = 0; i < 4 && i < sortedDistances.length; i++) {
        mergedText.write(sortedDistances[i].key);
        if (i < 3 && i < sortedDistances.length - 1) {
          mergedText.write('\n\n');
        }
      }

      return '''You are a helpful AI assistant for the attached document.
Use the following relevant context to answer the user's question accurately:

Context:
$mergedText

Question: $userPrompt''';
    } catch (e) {
      logError('Error in prompt generation: $e');
      return userPrompt;
    }
  }

  /// Calculates the Euclidean distance between two vectors.
  @override
  double calculateEuclideanDistance({
    required List<num> vectorA,
    required List<num> vectorB,
  }) {
    try {
      assert(
        vectorA.length == vectorB.length,
        'Vectors must be of the same length',
      );
      double sum = 0;
      for (int i = 0; i < vectorA.length; i++) {
        sum += (vectorA[i] - vectorB[i]) * (vectorA[i] - vectorB[i]);
      }
      return sqrt(sum);
    } catch (e) {
      logError('Error in calculating Euclidean distance: $e');
      rethrow;
    }
  }
}
