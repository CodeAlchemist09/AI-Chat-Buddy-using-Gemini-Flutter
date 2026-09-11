import 'dart:io';
import 'dart:typed_data';

import 'package:ai_buddy/core/config/type_of_bot.dart';
import 'package:ai_buddy/core/config/type_of_message.dart';
import 'package:ai_buddy/core/logger/logger.dart';
import 'package:ai_buddy/feature/gemini/gemini.dart';
import 'package:ai_buddy/feature/hive/model/chat_bot/chat_bot.dart';
import 'package:ai_buddy/feature/hive/model/chat_message/chat_message.dart';
import 'package:ai_buddy/feature/hive/repository/hive_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

final messageListProvider = StateNotifierProvider<MessageListNotifier, ChatBot>(
  (ref) => MessageListNotifier(),
);

class MessageListNotifier extends StateNotifier<ChatBot> {
  MessageListNotifier()
      : super(ChatBot(messagesList: [], id: '', title: '', typeOfBot: ''));

  final uuid = const Uuid();
  final geminiRepository = GeminiRepository();

  Future<void> updateChatBotWithMessage(ChatMessage message) async {
    final newMessageList = [...state.messagesList, message.toJson()];
    await updateChatBot(
      ChatBot(
        messagesList: newMessageList,
        id: state.id,
        title: state.title.isEmpty ? message.text : state.title,
        typeOfBot: state.typeOfBot,
        attachmentPath: state.attachmentPath,
        embeddings: state.embeddings,
      ),
    );
  }

  Future<void> _updateMessageText(String messageId, String newText) async {
    final int messageIndex =
        state.messagesList.indexWhere((msg) => msg['id'] == messageId);
    if (messageIndex != -1) {
      final newMessagesList =
          List<Map<String, dynamic>>.from(state.messagesList);
      newMessagesList[messageIndex] = Map<String, dynamic>.from(
        newMessagesList[messageIndex],
      );
      newMessagesList[messageIndex]['text'] = newText;
      final newState = ChatBot(
        id: state.id,
        title: state.title,
        typeOfBot: state.typeOfBot,
        messagesList: newMessagesList,
        attachmentPath: state.attachmentPath,
        embeddings: state.embeddings,
      );
      await updateChatBot(newState);
    }
  }

  Future<void> handleSendPressed({
    required String text,
    String? imageFilePath,
  }) async {
    final messageId = uuid.v4();
    final ChatMessage message = ChatMessage(
      id: messageId,
      text: text,
      createdAt: DateTime.now(),
      typeOfMessage: TypeOfMessage.user,
      chatBotId: state.id,
    );
    await updateChatBotWithMessage(message);
    await getGeminiResponse(prompt: text, imageFilePath: imageFilePath);
  }

  Future<void> getGeminiResponse({
    required String prompt,
    String? imageFilePath,
  }) async {
    // Construct multi-turn contents from existing messages
    final List<Map<String, dynamic>> contents = [];

    for (final msg in state.messagesList) {
      final msgText = msg['text'] as String? ?? '';
      if (msgText.isEmpty ||
          msgText == 'waiting for response...' ||
          msgText.startsWith('Error:')) {
        continue;
      }

      final isUser = msg['typeOfMessage'] == TypeOfMessage.user;
      final role = isUser ? 'user' : 'model';

      if (contents.isNotEmpty && contents.last['role'] == role) {
        final existingParts =
            (contents.last['parts'] as List).cast<Map<String, dynamic>>();
        existingParts.add({'text': msgText});
      } else {
        contents.add({
          'role': role,
          'parts': [
            {'text': msgText}
          ],
        });
      }
    }

    // Ensure the latest user prompt is present
    if (contents.isEmpty || contents.last['role'] != 'user') {
      contents.add({
        'role': 'user',
        'parts': [
          {'text': prompt}
        ],
      });
    }

    // Handle PDF bots
    Uint8List? docBytes;
    String? docMimeType;
    if (state.typeOfBot == TypeOfBot.pdf && state.attachmentPath != null) {
      final pdfFile = File(state.attachmentPath!);
      if (pdfFile.existsSync()) {
        try {
          final fileLength = await pdfFile.length();
          // Gemini inlineData supports up to ~20MB comfortably
          if (fileLength < 20 * 1024 * 1024) {
            docBytes = await pdfFile.readAsBytes();
            docMimeType = 'application/pdf';
          } else if (state.embeddings != null &&
              state.embeddings!.isNotEmpty) {
            // Fall back to embedding-based context for very large files
            final contextPrompt = await geminiRepository.promptForEmbedding(
              userPrompt: prompt,
              embeddings: state.embeddings,
            );
            contents.last['parts'] = [
              {'text': contextPrompt}
            ];
          }
        } catch (e) {
          logError('Error reading PDF attachment: $e');
        }
      }
    }

    // Handle Image bots
    Uint8List? imgBytes;
    String? imgMimeType;
    final activeImagePath = imageFilePath ?? state.attachmentPath;
    if (state.typeOfBot == TypeOfBot.image && activeImagePath != null) {
      final imgFile = File(activeImagePath);
      if (imgFile.existsSync()) {
        try {
          imgBytes = await imgFile.readAsBytes();
          final pathLower = activeImagePath.toLowerCase();
          if (pathLower.endsWith('.png')) {
            imgMimeType = 'image/png';
          } else if (pathLower.endsWith('.webp')) {
            imgMimeType = 'image/webp';
          } else if (pathLower.endsWith('.heic')) {
            imgMimeType = 'image/heic';
          } else {
            imgMimeType = 'image/jpeg';
          }
        } catch (e) {
          logError('Error reading image attachment: $e');
        }
      }
    }

    final String modelMessageId = uuid.v4();
    final placeholderMessage = ChatMessage(
      id: modelMessageId,
      text: 'waiting for response...',
      createdAt: DateTime.now(),
      typeOfMessage: TypeOfMessage.bot,
      chatBotId: state.id,
    );

    await updateChatBotWithMessage(placeholderMessage);

    final StringBuffer fullResponseText = StringBuffer();
    bool hasReceivedAnyChunk = false;

    try {
      final responseStream = geminiRepository.streamContent(
        contents: contents,
        image: imgBytes,
        imageMimeType: imgMimeType,
        document: docBytes,
        documentMimeType: docMimeType,
      );

      responseStream.listen(
        (response) async {
          if (response.content?.parts != null &&
              response.content!.parts!.isNotEmpty) {
            final chunkText = response.content!.parts!.first.text ?? '';
            if (chunkText.isNotEmpty) {
              hasReceivedAnyChunk = true;
              fullResponseText.write(chunkText);
              await _updateMessageText(
                modelMessageId,
                fullResponseText.toString(),
              );
            }
          }
        },
        onError: (error) async {
          logError('Error in response stream: $error');
          final cleanMsg = error
              .toString()
              .replaceFirst('Exception: ', '')
              .trim();
          final displayError = hasReceivedAnyChunk
              ? '${fullResponseText.toString()}\n\n[Interrupted: $cleanMsg]'
              : 'Error: $cleanMsg';
          await _updateMessageText(modelMessageId, displayError);
        },
        onDone: () async {
          if (!hasReceivedAnyChunk && fullResponseText.isEmpty) {
            await _updateMessageText(
              modelMessageId,
              'Error: No response received from Gemini.',
            );
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
      logError('Immediate error invoking Gemini: $e');
      final cleanMsg = e.toString().replaceFirst('Exception: ', '').trim();
      await _updateMessageText(modelMessageId, 'Error: $cleanMsg');
    }
  }

  Future<void> updateChatBot(ChatBot newChatBot) async {
    state = newChatBot;
    await HiveRepository().saveChatBot(chatBot: state);
  }
}
