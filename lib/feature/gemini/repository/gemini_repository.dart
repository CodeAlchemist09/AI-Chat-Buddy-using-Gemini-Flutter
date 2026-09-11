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

  // Cached active model name to avoid repeated discovery calls
  static String? _resolvedModel;

  // Active Free Tier multimodal Flash models in Google AI Studio (as of September 2026)
  static const List<String> defaultFreeTierModels = [
    'gemini-3.8-flash',
    'gemini-3.1-flash-lite',
    'gemini-3-flash-preview',
    'gemini-2.5-flash',
    'gemini-2.0-flash',
  ];

  /// Dynamically queries Google AI Studio models.list endpoint to find active
  /// Free Tier Multimodal Flash models (text, images, PDFs) for the user's API key.
  Future<List<String>> getAvailableFreeTierModels(String apiKey) async {
    try {
      final res = await dio.get<dynamic>(
        'https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey',
        options: Options(
          headers: {'Content-Type': 'application/json'},
        ),
      );

      dynamic data = res.data;
      if (data is String) {
        try {
          data = jsonDecode(data);
        } catch (_) {}
      }

      if (data is Map) {
        final rawList = data['models'];
        if (rawList is List && rawList.isNotEmpty) {
          final List<String> freeTierModels = [];
          for (final item in rawList) {
            if (item is Map) {
              final name = item['name']?.toString() ?? '';
              final lower = name.toLowerCase();
              final methods = item['supportedGenerationMethods'];
              final isGenContent = methods is List &&
                  methods.any((m) => m.toString() == 'generateContent');

              // Exclude specialized non-text or paid models:
              // - tts / audio-only
              // - live / realtime
              // - embed / embedding
              // - imagen
              // - pro (requires paid billing)
              final isSpecialized = lower.contains('tts') ||
                  lower.contains('audio') ||
                  lower.contains('embed') ||
                  lower.contains('imagen') ||
                  lower.contains('live') ||
                  lower.contains('realtime') ||
                  lower.contains('pro');

              // Strictly Free Tier Multimodal Text Models
              if (isGenContent && lower.contains('flash') && !isSpecialized) {
                final cleanId = name.replaceFirst('models/', '');
                freeTierModels.add(cleanId);
              }
            }
          }

          if (freeTierModels.isNotEmpty) {
            // Sort by priority: prefer 3.8-flash, 3.1-flash-lite, 3-flash, 2.5-flash, 2.0-flash
            freeTierModels.sort((a, b) {
              int score(String id) {
                final lowerId = id.toLowerCase();
                if (lowerId.contains('3.8-flash')) return 100;
                if (lowerId.contains('3.1-flash-lite')) return 90;
                if (lowerId.contains('3-flash')) return 80;
                if (lowerId.contains('2.5-flash')) return 70;
                if (lowerId.contains('2.0-flash')) return 60;
                if (lowerId.contains('flash')) return 50;
                return 0;
              }

              return score(b).compareTo(score(a));
            });

            logInfo(
              'Discovered free-tier multimodal Flash models for this API key: $freeTierModels',
            );
            return freeTierModels;
          }
        }
      }
    } catch (e) {
      logError('Could not dynamically list free-tier models: $e');
    }

    return defaultFreeTierModels;
  }

  /// Streams content from the Gemini API using Server-Sent Events (SSE)
  /// or robust JSON chunk parsing. Supports multi-turn conversations,
  /// images, and PDF documents exclusively with Free Tier Flash models.
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

    // Determine candidate models strictly from multimodal Free Tier Flash models
    final List<String> candidateModels = [];

    if (model != null &&
        model.isNotEmpty &&
        !model.toLowerCase().contains('tts') &&
        !model.toLowerCase().contains('audio')) {
      candidateModels.add(model.replaceFirst('models/', ''));
    }
    if (_resolvedModel != null &&
        _resolvedModel!.isNotEmpty &&
        !_resolvedModel!.toLowerCase().contains('tts') &&
        !_resolvedModel!.toLowerCase().contains('audio')) {
      candidateModels.add(_resolvedModel!);
    }

    // Fetch live free-tier multimodal models from Google API
    final liveFreeTier = await getAvailableFreeTierModels(apiKey);
    candidateModels.addAll(liveFreeTier);
    candidateModels.addAll(defaultFreeTierModels);

    Response<ResponseBody>? response;
    DioException? lastDioException;

    final uniqueCandidates = candidateModels.toSet().toList();

    for (final candidate in uniqueCandidates) {
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
        logInfo('Connected successfully using Free Tier model: $candidate');
        break; // Successfully connected!
      } on DioException catch (dioErr) {
        lastDioException = dioErr;
        if (dioErr.response?.statusCode == 404 ||
            dioErr.response?.statusCode == 400) {
          logError(
            'Model $candidate returned ${dioErr.response?.statusCode}. Trying next candidate...',
          );
          _resolvedModel = null;
          continue; // Try next candidate
        } else {
          final errorMsg = await _extractDioErrorMessage(dioErr);
          logError('DioException in streamContent: $errorMsg');
          _resolvedModel = null;
          throw Exception(errorMsg);
        }
      } catch (e) {
        logError('Network error in streamContent: $e');
        _resolvedModel = null;
        throw Exception('Connection failed: $e');
      }
    }

    if (response == null || response.statusCode != 200) {
      if (lastDioException != null) {
        final errorMsg = await _extractDioErrorMessage(lastDioException);
        throw Exception(errorMsg);
      }
      throw Exception(
        'Failed to connect to any Free Tier Gemini Multimodal Flash model.',
      );
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
        buffer = ''; // Successfully decoded full JSON object

        if (decoded is Map<String, dynamic>) {
          if (decoded.containsKey('error')) {
            final errorMap = decoded['error'] as Map<String, dynamic>?;
            final message = errorMap?['message']?.toString() ??
                'Gemini API returned an error';
            _resolvedModel = null;
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
          _resolvedModel = null;
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
      return 'Invalid request or model modality unsupported. Please check model availability.';
    }
    if (dioErr.response?.statusCode == 403) {
      return 'Permission denied. Make sure your API key has access to the Gemini API.';
    }
    if (dioErr.response?.statusCode == 404) {
      return 'Free Tier model not found. Retrying with next available model...';
    }
    if (dioErr.response?.statusCode == 429) {
      return 'Gemini API free tier rate limit reached. Please wait a moment and try again.';
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
