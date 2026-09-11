import 'dart:io';

import 'package:ai_buddy/core/logger/logger.dart';
import 'package:ai_buddy/feature/gemini/repository/gemini_repository.dart';
import 'package:ai_buddy/feature/hive/model/chat_bot/chat_bot.dart';
import 'package:ai_buddy/feature/hive/repository/hive_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

final chatBotListProvider =
    StateNotifierProvider<ChatBotListNotifier, List<ChatBot>>(
  (ref) => ChatBotListNotifier(),
);

class ChatBotListNotifier extends StateNotifier<List<ChatBot>> {
  ChatBotListNotifier() : super([]) {
    hiveRepository = HiveRepository();
    dio = Dio();
    geminiRepository = GeminiRepository();
  }

  late final HiveRepository hiveRepository;
  late final Dio dio;
  late final GeminiRepository geminiRepository;

  Future<String?> attachImageFilePath({
    ImageSource source = ImageSource.gallery,
  }) async {
    try {
      final pickedFile = await ImagePicker().pickImage(
        source: source,
        imageQuality: 85,
      );
      return pickedFile?.path;
    } catch (e) {
      logError('Error picking image: $e');
      return null;
    }
  }

  Future<void> fetchChatBots() async {
    final chatBotsList = await hiveRepository.getChatBots();
    state = chatBotsList;
  }

  Future<void> saveChatBot(ChatBot chatBot) async {
    await hiveRepository.saveChatBot(chatBot: chatBot);
    state = [chatBot, ...state];
  }

  Future<void> updateChatBotOnHomeScreen(ChatBot chatBot) async {
    final index = state.indexWhere((element) => element.id == chatBot.id);
    if (index != -1) {
      state[index] = chatBot;
      state = List.from(state);
    }
    await deleteChatBotsWithEmptyTitle();
  }

  Future<void> deleteChatBotsWithEmptyTitle() async {
    final chatBotsWithNonEmptyTitle =
        state.where((chatBot) => chatBot.title.isNotEmpty).toList();
    for (final chatBot in state.where((chatBot) => chatBot.title.isEmpty)) {
      await hiveRepository.deleteChatBot(chatBot: chatBot);
    }
    state = chatBotsWithNonEmptyTitle;
  }

  Future<void> deleteChatBot(ChatBot chatBot) async {
    await hiveRepository.deleteChatBot(chatBot: chatBot);
    state = state.where((item) => item.id != chatBot.id).toList();
  }

  Future<Map<String, List<num>>> batchEmbedChunks(
    List<String> textChunks,
  ) async {
    try {
      final response =
          await geminiRepository.batchEmbedChunks(textChunks: textChunks);
      return response;
    } catch (e) {
      logError('Failed to generate embeddings: $e');
      return {};
    }
  }

  Future<List<String>> getChunksFromPDF(String filePath) async {
    try {
      final List<String> pageTextChunks = [];
      final file = File(filePath);
      if (!file.existsSync()) return [];

      final PdfDocument document = PdfDocument(
        inputBytes: await file.readAsBytes(),
      );

      final PdfTextExtractor extractor = PdfTextExtractor(document);

      for (int pageIndex = 0; pageIndex < document.pages.count; pageIndex++) {
        final text = extractor.extractText(
          startPageIndex: pageIndex,
          endPageIndex: pageIndex,
        );
        final trimmed = text.trim();
        if (trimmed.isNotEmpty) {
          pageTextChunks.add(trimmed);
        }
      }
      return pageTextChunks;
    } catch (e) {
      logError('Error extracting text from PDF: $e');
      return [];
    }
  }
}
