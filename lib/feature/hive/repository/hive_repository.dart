import 'package:ai_buddy/feature/hive/model/chat_bot/chat_bot.dart';
import 'package:ai_buddy/feature/hive/repository/base_hive_repository.dart';
import 'package:hive/hive.dart';

class HiveRepository implements BaseHiveRepository {
  HiveRepository();

  Box<ChatBot> get _chatBot {
    if (Hive.isBoxOpen('chatbots')) {
      return Hive.box<ChatBot>('chatbots');
    }
    throw StateError('Hive box chatbots has not been opened yet.');
  }

  @override
  Future<void> saveChatBot({required ChatBot chatBot}) async {
    final box = Hive.isBoxOpen('chatbots')
        ? Hive.box<ChatBot>('chatbots')
        : await Hive.openBox<ChatBot>('chatbots');
    await box.put(chatBot.id, chatBot);
  }

  @override
  Future<List<ChatBot>> getChatBots() async {
    final box = Hive.isBoxOpen('chatbots')
        ? Hive.box<ChatBot>('chatbots')
        : await Hive.openBox<ChatBot>('chatbots');
    return box.values.toList();
  }

  @override
  Future<void> deleteChatBot({required ChatBot chatBot}) async {
    final box = Hive.isBoxOpen('chatbots')
        ? Hive.box<ChatBot>('chatbots')
        : await Hive.openBox<ChatBot>('chatbots');
    await box.delete(chatBot.id);
  }
}
