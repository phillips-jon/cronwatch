package dev.cronwatch.storetest;

import dev.cronwatch.jdbc.SqlStore;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.sqlite.SQLiteDataSource;

/**
 * The finish-once scenarios over the memory store (every process on one store) and over SQLite
 * (every process a store of its own on one file), as several processes would share a database.
 */
class FinishOnceTest {
  @Test
  void onTheMemoryStore() {
    FinishOnce.run(
        () -> {
          MemoryStore store = new MemoryStore();
          return new FinishOnce.Shared() {
            @Override
            public Store open() {
              return store;
            }

            @Override
            public void done() {}
          };
        });
  }

  @Test
  void onSqliteFiles() {
    FinishOnce.run(
        () -> {
          Path dir;
          try {
            dir = Files.createTempDirectory("cronwatch-once-");
          } catch (IOException e) {
            throw new AssertionError(e);
          }
          Path file = dir.resolve("cw.db");
          List<Store> opened = new ArrayList<>();
          return new FinishOnce.Shared() {
            @Override
            public Store open() {
              SQLiteDataSource source = new SQLiteDataSource();
              source.setUrl("jdbc:sqlite:" + file);
              Store s = SqlStore.sqlite(source);
              opened.add(s);
              return s;
            }

            @Override
            public void done() throws Exception {
              for (Store s : opened) {
                s.close();
              }
              try (Stream<Path> files = Files.walk(dir)) {
                for (Path p : files.sorted(Comparator.reverseOrder()).toList()) {
                  Files.deleteIfExists(p);
                }
              }
            }
          };
        });
  }
}
