package dev.cronwatch.storetest;

import static org.junit.jupiter.api.Assertions.assertEquals;

import dev.cronwatch.Fixtures;
import dev.cronwatch.JobState;
import dev.cronwatch.store.MemoryStore;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import org.junit.jupiter.api.Test;

/** The memory store through the store contract and every case of conformance/store.json. */
class MemoryStoreContractTest {
  static String fixture() throws IOException {
    return Files.readString(
        Fixtures.conformanceDir().resolve("store.json"), StandardCharsets.UTF_8);
  }

  @Test
  void theMemoryStorePassesTheContract() {
    StoreContract.run(new MemoryStore());
  }

  @Test
  void theMemoryStoreReplaysStoreJson() throws IOException {
    assertEquals(26, StoreReplay.run(fixture(), MemoryStore::new));
  }

  @Test
  void theMemoryStoreCountsAForeignStatesVersionAsTheSdkDoes() throws IOException {
    MemoryStore store = new MemoryStore();
    assertEquals(
        16,
        StoreReplay.foreignVersions(
            fixture(), store, text -> store.setState(JobState.fromJson(text))));
  }
}
