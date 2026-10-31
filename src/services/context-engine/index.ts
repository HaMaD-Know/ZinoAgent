import { contextRepo, messagesRepo } from '@/database/repositories';
import type { ContextStore } from './engine';

export * from './engine';
export * from './tokenizer';
export * from './batcher';
export * from './verifier';
export * from './retrieval';

/** SQLite-backed store used by the app. */
export const repoContextStore: ContextStore = {
  listMessages: (chatId) => messagesRepo.list(chatId),
  batches: (chatId) => contextRepo.batches(chatId),
  summaries: (chatId) => contextRepo.summaries(chatId),
  memory: (chatId) => contextRepo.memory(chatId),
  saveBatchWithSummary: (b, s, m) => contextRepo.saveBatchWithSummary(b, s, m),
  saveRollup: (s) => contextRepo.saveRollup(s),
  setTokenCounts: (u) => messagesRepo.setTokenCounts(u),
};
