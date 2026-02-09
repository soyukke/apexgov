package samples;

import apexemu.annotations.Test;
import apexemu.runtime.ApexDb;
import apexemu.runtime.Async;
import apexemu.runtime.ApexSObject;
import apexemu.runtime.Database;
import apexemu.runtime.Limits;
import apexemu.runtime.QueryLocatorBatchable;
import apexemu.runtime.Schema;
import apexemu.runtime.SystemAssert;
import apexemu.runtime.Trigger;
import java.util.List;
import java.util.Map;

public final class SampleGovernorTest {
  @Test
  public void countsSoqlAndDml() {
    for (int i = 0; i < 5; i += 1) {
      ApexDb.queryRows(20);
    }
    ApexDb.dmlRows(3);

    Limits.Snapshot snapshot = Limits.snapshot();
    SystemAssert.assertEquals(5, snapshot.soqlCount(), "SOQL count mismatch");
    SystemAssert.assertEquals(1, snapshot.dmlCount(), "DML count mismatch");
    SystemAssert.assertTrue(snapshot.heapBytes() > 0, "Heap tracking should be positive");
  }

  @Test
  public void cpuBurnWithinBudget() {
    ApexDb.cpuBurnMs(10);
    SystemAssert.assertTrue(true, "cpu burn should be allowed");
  }

  @Test
  public void startStopScopesWindowMetrics() {
    // setup phase (outside start/stop window)
    ApexDb.cpuBurnMs(20);
    ApexDb.queryRows(10);
    ApexDb.queryRows(10);
    long cpuBeforeWindow = Limits.getCpuTime();

    apexemu.runtime.Test.startTest();
    ApexDb.queryRows(5);
    ApexDb.queryRows(5);
    ApexDb.queryRows(5);
    ApexDb.dmlRows(2);
    apexemu.runtime.Test.stopTest();

    SystemAssert.assertEquals(3, Limits.getQueries(), "startTest window should reset query counter");
    SystemAssert.assertEquals(1, Limits.getDmlStatements(), "window DML count mismatch");
    SystemAssert.assertTrue(Limits.getCpuTime() >= 1, "window cpu should be measured");
    SystemAssert.assertTrue(
        Limits.getCpuTime() < cpuBeforeWindow, "window cpu should exclude setup-phase cpu burn");
    SystemAssert.assertTrue(
        Limits.getCpuTime() <= Limits.getLimitCpuTime(), "window cpu should be within configured limit");
    SystemAssert.assertTrue(
        Limits.getHeapSize() <= Limits.getLimitHeapSize(),
        "window heap should be within configured limit");
  }

  @Test
  public void asyncJobsFlushAtStopTest() {
    FutureWorker.reset();
    final int[] score = new int[] {0};

    apexemu.runtime.Test.startTest();
    apexemu.runtime.Test.enqueueFutureMethod(FutureWorker.class, "futureWork");
    apexemu.runtime.System.enqueueJob(() -> score[0] += 10);
    Database.executeBatch(scopeSize -> score[0] += scopeSize, 3);
    apexemu.runtime.System.schedule("nightly", "0 0 * * * ?", () -> score[0] += 100);
    apexemu.runtime.Test.stopTest();

    SystemAssert.assertEquals(1, FutureWorker.executed, "future method should run on stopTest");
    SystemAssert.assertEquals(113, score[0], "queueable/batch/schedulable should be flushed");

    Async.Snapshot snapshot = apexemu.runtime.Test.getAsyncSnapshot();
    SystemAssert.assertEquals(4, snapshot.enqueuedJobs(), "expected 4 async enqueues");
    SystemAssert.assertEquals(4, snapshot.flushedJobs(), "all async jobs should be flushed");
    SystemAssert.assertEquals(0, snapshot.pendingJobs(), "pending queue must be empty after stopTest");
  }

  @Test
  public void queryLocatorBatchSplitsByScopeAndCallsFinishOnce() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "A"),
            ApexSObject.of("Account").set("Name", "B"),
            ApexSObject.of("Account").set("Name", "C"),
            ApexSObject.of("Account").set("Name", "D"),
            ApexSObject.of("Account").set("Name", "E")));

    final List<Integer> scopeSizes = new java.util.ArrayList<>();
    final List<String> seenNames = new java.util.ArrayList<>();
    final int[] finishCount = new int[] {0};

    apexemu.runtime.Test.startTest();
    Database.executeBatch(
        new QueryLocatorBatchable() {
          @Override
          public Database.QueryLocator start() {
            return Database.getQueryLocator("SELECT Id, Name FROM Account ORDER BY Name ASC");
          }

          @Override
          public void execute(List<ApexSObject> scope) {
            scopeSizes.add(scope.size());
            for (ApexSObject row : scope) {
              seenNames.add(String.valueOf(row.get("Name")));
            }
            if (!scope.isEmpty()) {
              scope.get(0).set("Name", "Mutated-In-Scope");
            }
          }

          @Override
          public void finish() {
            finishCount[0] += 1;
          }
        },
        2);
    apexemu.runtime.Test.stopTest();

    SystemAssert.assertEquals(3, scopeSizes.size(), "query locator batch should split into 3 chunks");
    SystemAssert.assertEquals(2, scopeSizes.get(0), "chunk#1 size mismatch");
    SystemAssert.assertEquals(2, scopeSizes.get(1), "chunk#2 size mismatch");
    SystemAssert.assertEquals(1, scopeSizes.get(2), "chunk#3 size mismatch");
    SystemAssert.assertEquals(1, finishCount[0], "finish should run exactly once");

    SystemAssert.assertEquals(5, seenNames.size(), "all rows should be processed");
    SystemAssert.assertEquals("A", seenNames.get(0), "processed order mismatch");
    SystemAssert.assertEquals("B", seenNames.get(1), "processed order mismatch");
    SystemAssert.assertEquals("C", seenNames.get(2), "processed order mismatch");
    SystemAssert.assertEquals("D", seenNames.get(3), "processed order mismatch");
    SystemAssert.assertEquals("E", seenNames.get(4), "processed order mismatch");

    List<ApexSObject> persisted = Database.query("SELECT Id, Name FROM Account ORDER BY Name ASC");
    SystemAssert.assertEquals("A", persisted.get(0).get("Name"), "scope mutation must not alter stored rows");
  }

  @Test
  public void queryLocatorBatchStartMustReturnNonNull() {
    final int[] finishCount = new int[] {0};

    boolean threw = false;
    try {
      apexemu.runtime.Test.startTest();
      Database.executeBatch(
          new QueryLocatorBatchable() {
            @Override
            public Database.QueryLocator start() {
              return null;
            }

            @Override
            public void execute(List<ApexSObject> scope) {}

            @Override
            public void finish() {
              finishCount[0] += 1;
            }
          },
          2);
      apexemu.runtime.Test.stopTest();
    } catch (IllegalArgumentException expected) {
      threw = true;
      SystemAssert.assertTrue(
          expected.getMessage().contains("batch start cannot return null query locator"),
          "null start should report explicit message");
    }

    SystemAssert.assertTrue(threw, "null query locator from start must throw");
    SystemAssert.assertEquals(0, finishCount[0], "finish should not run when start returns null");
  }

  @Test
  public void queryLocatorBatchExecuteScopesUseFreshLimits() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "A"),
            ApexSObject.of("Account").set("Name", "B"),
            ApexSObject.of("Account").set("Name", "C"),
            ApexSObject.of("Account").set("Name", "D"),
            ApexSObject.of("Account").set("Name", "E")));

    final List<Integer> scopeQueryCounts = new java.util.ArrayList<>();
    final List<Integer> scopeDmlCounts = new java.util.ArrayList<>();

    apexemu.runtime.Test.startTest();
    Database.executeBatch(
        new QueryLocatorBatchable() {
          @Override
          public Database.QueryLocator start() {
            return Database.getQueryLocator("SELECT Id, Name FROM Account ORDER BY Name ASC");
          }

          @Override
          public void execute(List<ApexSObject> scope) {
            ApexDb.queryRows(scope.size());
            ApexDb.dmlRows(scope.size());
            scopeQueryCounts.add(Limits.getQueries());
            scopeDmlCounts.add(Limits.getDmlStatements());
          }
        },
        2);
    apexemu.runtime.Test.stopTest();

    SystemAssert.assertEquals(3, scopeQueryCounts.size(), "scope execution count mismatch");
    SystemAssert.assertEquals(1, scopeQueryCounts.get(0), "scope#1 query count should start from 1");
    SystemAssert.assertEquals(1, scopeQueryCounts.get(1), "scope#2 query count should reset to 1");
    SystemAssert.assertEquals(1, scopeQueryCounts.get(2), "scope#3 query count should reset to 1");

    SystemAssert.assertEquals(3, scopeDmlCounts.size(), "scope execution count mismatch");
    SystemAssert.assertEquals(1, scopeDmlCounts.get(0), "scope#1 dml count should start from 1");
    SystemAssert.assertEquals(1, scopeDmlCounts.get(1), "scope#2 dml count should reset to 1");
    SystemAssert.assertEquals(1, scopeDmlCounts.get(2), "scope#3 dml count should reset to 1");

    SystemAssert.assertEquals(0, Limits.getQueries(), "batch sub-transactions should not leak query count");
    SystemAssert.assertEquals(0, Limits.getDmlStatements(), "batch sub-transactions should not leak dml count");
  }

  @Test
  public void queryLocatorBatchScopeExceedingCpuLimitFails() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(List.of(ApexSObject.of("Account").set("Name", "A")));

    int originalCpuLimit = Limits.getLimitCpuTime();
    long originalHeapLimit = Limits.getLimitHeapSize();
    Limits.configure(5, originalHeapLimit);

    boolean threw = false;
    try {
      apexemu.runtime.Test.startTest();
      Database.executeBatch(
          new QueryLocatorBatchable() {
            @Override
            public Database.QueryLocator start() {
              return Database.getQueryLocator("SELECT Id, Name FROM Account");
            }

            @Override
            public void execute(List<ApexSObject> scope) {
              ApexDb.cpuBurnMs(8);
            }
          },
          1);
      apexemu.runtime.Test.stopTest();
    } catch (AssertionError expected) {
      threw = true;
      SystemAssert.assertTrue(
          expected.getMessage().contains("CPU limit exceeded"),
          "batch scope cpu overflow should report cpu limit message");
    } finally {
      Limits.configure(originalCpuLimit, originalHeapLimit);
    }

    SystemAssert.assertTrue(threw, "batch scope exceeding cpu limit must fail");
  }

  @Test
  public void triggerContextFlagsAndMapsWork() {
    TriggerRow before = new TriggerRow("001xx0000001", "Before");
    TriggerRow after = new TriggerRow("001xx0000001", "After");

    Trigger.beforeUpdate(
        List.of(before),
        List.of(after),
        () -> {
          SystemAssert.assertTrue(Trigger.isExecuting(), "trigger should be executing");
          SystemAssert.assertTrue(Trigger.isBefore(), "expected before context");
          SystemAssert.assertFalse(Trigger.isAfter(), "before context should not be after");
          SystemAssert.assertTrue(Trigger.isUpdate(), "expected update context");
          SystemAssert.assertEquals(1, Trigger.size(), "trigger size mismatch");
          SystemAssert.assertEquals(1, Trigger.getNew().size(), "Trigger.new size mismatch");
          SystemAssert.assertEquals(1, Trigger.getOld().size(), "Trigger.old size mismatch");
          SystemAssert.assertNotNull(
              Trigger.getNewMap().get("001xx0000001"), "Trigger.newMap should contain id key");

          TriggerRow newRow = (TriggerRow) Trigger.getNewMap().get("001xx0000001");
          TriggerRow oldRow = (TriggerRow) Trigger.getOldMap().get("001xx0000001");
          SystemAssert.assertEquals("After", newRow.name, "newMap row should be after-image");
          SystemAssert.assertEquals("Before", oldRow.name, "oldMap row should be before-image");
        });

    SystemAssert.assertFalse(Trigger.isExecuting(), "trigger state should be cleared after run");
  }

  @Test
  public void databaseCrudAutoDispatchesRegisteredTriggers() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();
    Database.clearTriggerHandlers();

    final int[] beforeInsertCount = new int[] {0};
    final int[] afterInsertCount = new int[] {0};
    final int[] beforeUpdateCount = new int[] {0};
    final int[] afterUpdateCount = new int[] {0};
    final int[] beforeDeleteCount = new int[] {0};
    final int[] afterDeleteCount = new int[] {0};
    final int[] afterUndeleteCount = new int[] {0};

    Trigger.onBeforeInsert(
        "Account",
        () -> {
          beforeInsertCount[0] += 1;
          SystemAssert.assertTrue(Trigger.isBefore(), "before-insert should set isBefore");
          SystemAssert.assertTrue(Trigger.isInsert(), "before-insert should set isInsert");
          SystemAssert.assertEquals(2, Trigger.size(), "before-insert trigger size mismatch");
          for (Object row : Trigger.getNew()) {
            ApexSObject sobject = (ApexSObject) row;
            sobject.set("Name", String.valueOf(sobject.get("Name")) + "-BI");
          }
        });

    Trigger.onAfterInsert(
        "Account",
        () -> {
          afterInsertCount[0] += 1;
          SystemAssert.assertTrue(Trigger.isAfter(), "after-insert should set isAfter");
          SystemAssert.assertTrue(Trigger.isInsert(), "after-insert should set isInsert");
          SystemAssert.assertEquals(2, Trigger.size(), "after-insert trigger size mismatch");
        });

    Trigger.onBeforeUpdate(
        "Account",
        () -> {
          beforeUpdateCount[0] += 1;
          SystemAssert.assertTrue(Trigger.isBefore(), "before-update should set isBefore");
          SystemAssert.assertTrue(Trigger.isUpdate(), "before-update should set isUpdate");
          SystemAssert.assertEquals(2, Trigger.getOld().size(), "before-update old size mismatch");
          SystemAssert.assertEquals(2, Trigger.getNew().size(), "before-update new size mismatch");
          for (Object row : Trigger.getNew()) {
            ApexSObject sobject = (ApexSObject) row;
            sobject.set("Name", String.valueOf(sobject.get("Name")) + "-BU");
          }
        });

    Trigger.onAfterUpdate(
        "Account",
        () -> {
          afterUpdateCount[0] += 1;
          SystemAssert.assertTrue(Trigger.isAfter(), "after-update should set isAfter");
          SystemAssert.assertTrue(Trigger.isUpdate(), "after-update should set isUpdate");
          SystemAssert.assertEquals(2, Trigger.getOld().size(), "after-update old size mismatch");
          SystemAssert.assertEquals(2, Trigger.getNew().size(), "after-update new size mismatch");
        });

    Trigger.onBeforeDelete(
        "Account",
        () -> {
          beforeDeleteCount[0] += 1;
          SystemAssert.assertTrue(Trigger.isBefore(), "before-delete should set isBefore");
          SystemAssert.assertTrue(Trigger.isDelete(), "before-delete should set isDelete");
          SystemAssert.assertEquals(1, Trigger.getOld().size(), "before-delete old size mismatch");
        });

    Trigger.onAfterDelete(
        "Account",
        () -> {
          afterDeleteCount[0] += 1;
          SystemAssert.assertTrue(Trigger.isAfter(), "after-delete should set isAfter");
          SystemAssert.assertTrue(Trigger.isDelete(), "after-delete should set isDelete");
          SystemAssert.assertEquals(1, Trigger.getOld().size(), "after-delete old size mismatch");
        });

    Trigger.onAfterUndelete(
        "Account",
        () -> {
          afterUndeleteCount[0] += 1;
          SystemAssert.assertTrue(Trigger.isAfter(), "after-undelete should set isAfter");
          SystemAssert.assertTrue(Trigger.isUndelete(), "after-undelete should set isUndelete");
          SystemAssert.assertEquals(1, Trigger.getNew().size(), "after-undelete new size mismatch");
        });

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Alpha"),
            ApexSObject.of("Account").set("Name", "Beta")));

    List<ApexSObject> inserted = Database.query("SELECT Id, Name FROM Account ORDER BY Name ASC");
    SystemAssert.assertEquals("Alpha-BI", inserted.get(0).get("Name"), "before-insert mutation mismatch");
    SystemAssert.assertEquals("Beta-BI", inserted.get(1).get("Name"), "before-insert mutation mismatch");

    Database.update(
        List.of(
            ApexSObject.of("Account").withId(inserted.get(0).id()).set("Name", "Alpha-U"),
            ApexSObject.of("Account").withId(inserted.get(1).id()).set("Name", "Beta-U")));

    List<ApexSObject> updated = Database.query("SELECT Id, Name FROM Account ORDER BY Name ASC");
    SystemAssert.assertEquals("Alpha-U-BU", updated.get(0).get("Name"), "before-update mutation mismatch");
    SystemAssert.assertEquals("Beta-U-BU", updated.get(1).get("Name"), "before-update mutation mismatch");

    ApexSObject target = ApexSObject.of("Account").withId(updated.get(0).id());
    Database.delete(List.of(target));
    Database.undelete(List.of(target));

    SystemAssert.assertEquals(1, beforeInsertCount[0], "before-insert should run once");
    SystemAssert.assertEquals(1, afterInsertCount[0], "after-insert should run once");
    SystemAssert.assertEquals(1, beforeUpdateCount[0], "before-update should run once");
    SystemAssert.assertEquals(1, afterUpdateCount[0], "after-update should run once");
    SystemAssert.assertEquals(1, beforeDeleteCount[0], "before-delete should run once");
    SystemAssert.assertEquals(1, afterDeleteCount[0], "after-delete should run once");
    SystemAssert.assertEquals(1, afterUndeleteCount[0], "after-undelete should run once");
  }

  @Test
  public void upsertAutoDispatchesInsertAndUpdateTriggers() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();
    Database.clearTriggerHandlers();

    Database.insert(List.of(ApexSObject.of("Account").set("Name", "Seed")));
    ApexSObject seed = Database.query("SELECT Id, Name FROM Account LIMIT 1").get(0);

    final int[] beforeInsert = new int[] {0};
    final int[] afterInsert = new int[] {0};
    final int[] beforeUpdate = new int[] {0};
    final int[] afterUpdate = new int[] {0};

    Trigger.onBeforeInsert(
        "Account",
        () -> {
          beforeInsert[0] += 1;
          SystemAssert.assertTrue(Trigger.isInsert(), "upsert insert path should use insert context");
          for (Object row : Trigger.getNew()) {
            ApexSObject sobject = (ApexSObject) row;
            sobject.set("Name", String.valueOf(sobject.get("Name")) + "-BIU");
          }
        });
    Trigger.onAfterInsert("Account", () -> afterInsert[0] += 1);

    Trigger.onBeforeUpdate(
        "Account",
        () -> {
          beforeUpdate[0] += 1;
          SystemAssert.assertTrue(Trigger.isUpdate(), "upsert update path should use update context");
          SystemAssert.assertEquals(1, Trigger.getOld().size(), "update-old size should be 1");
          for (Object row : Trigger.getNew()) {
            ApexSObject sobject = (ApexSObject) row;
            sobject.set("Name", String.valueOf(sobject.get("Name")) + "-BUU");
          }
        });
    Trigger.onAfterUpdate("Account", () -> afterUpdate[0] += 1);

    Database.upsert(
        List.of(
            ApexSObject.of("Account").withId(seed.id()).set("Name", "Seed-Updated"),
            ApexSObject.of("Account").set("Name", "Fresh")),
        true);

    SystemAssert.assertEquals(1, beforeInsert[0], "upsert should fire before insert once");
    SystemAssert.assertEquals(1, afterInsert[0], "upsert should fire after insert once");
    SystemAssert.assertEquals(1, beforeUpdate[0], "upsert should fire before update once");
    SystemAssert.assertEquals(1, afterUpdate[0], "upsert should fire after update once");

    List<ApexSObject> rows = Database.query("SELECT Id, Name FROM Account ORDER BY Name ASC");
    SystemAssert.assertEquals(2, rows.size(), "upsert should leave two rows");
    SystemAssert.assertEquals("Fresh-BIU", rows.get(0).get("Name"), "insert-side trigger mutation missing");
    SystemAssert.assertEquals(
        "Seed-Updated-BUU", rows.get(1).get("Name"), "update-side trigger mutation missing");
  }

  @Test
  public void mergeAutoDispatchesUpdateAndDeleteTriggers() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();
    Database.clearTriggerHandlers();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Master"),
            ApexSObject.of("Account").set("Name", "Dup-A"),
            ApexSObject.of("Account").set("Name", "Dup-B")));

    ApexSObject master = Database.query("SELECT Id, Name FROM Account WHERE Name = 'Master' LIMIT 1").get(0);
    ApexSObject duplicateA = Database.query("SELECT Id, Name FROM Account WHERE Name = 'Dup-A' LIMIT 1").get(0);
    ApexSObject duplicateB = Database.query("SELECT Id, Name FROM Account WHERE Name = 'Dup-B' LIMIT 1").get(0);

    final int[] beforeUpdateCount = new int[] {0};
    final int[] afterUpdateCount = new int[] {0};
    final int[] beforeDeleteCount = new int[] {0};
    final int[] afterDeleteCount = new int[] {0};

    Trigger.onBeforeUpdate(
        "Account",
        () -> {
          beforeUpdateCount[0] += 1;
          SystemAssert.assertTrue(Trigger.isUpdate(), "merge should dispatch update context");
          SystemAssert.assertEquals(1, Trigger.getOld().size(), "merge update old size mismatch");
          ApexSObject row = (ApexSObject) Trigger.getNew().get(0);
          row.set("Name", String.valueOf(row.get("Name")) + "-BM");
        });
    Trigger.onAfterUpdate("Account", () -> afterUpdateCount[0] += 1);
    Trigger.onBeforeDelete(
        "Account",
        () -> {
          beforeDeleteCount[0] += 1;
          SystemAssert.assertTrue(Trigger.isDelete(), "merge should dispatch delete context");
          SystemAssert.assertEquals(2, Trigger.getOld().size(), "merge delete old size mismatch");
        });
    Trigger.onAfterDelete(
        "Account",
        () -> {
          afterDeleteCount[0] += 1;
          SystemAssert.assertTrue(Trigger.isDelete(), "merge should dispatch delete context");
          SystemAssert.assertEquals(2, Trigger.getOld().size(), "merge delete old size mismatch");
        });

    Database.MergeResult mergeResult =
        Database.merge(
            ApexSObject.of("Account").withId(master.id()).set("Name", "Master-Merged"),
            List.of(
                ApexSObject.of("Account").withId(duplicateA.id()),
                ApexSObject.of("Account").withId(duplicateB.id())),
            true);
    SystemAssert.assertTrue(mergeResult.isSuccess(), "merge result should succeed");
    SystemAssert.assertEquals(master.id(), mergeResult.getId(), "merge result id should be master id");
    SystemAssert.assertEquals(2, mergeResult.getMergedRecordIds().length, "merged id list size mismatch");
    SystemAssert.assertEquals(0, mergeResult.getUpdatedRelatedIds().length, "updated related ids should be empty");

    SystemAssert.assertEquals(1, beforeUpdateCount[0], "merge should fire before-update once");
    SystemAssert.assertEquals(1, afterUpdateCount[0], "merge should fire after-update once");
    SystemAssert.assertEquals(1, beforeDeleteCount[0], "merge should fire before-delete once");
    SystemAssert.assertEquals(1, afterDeleteCount[0], "merge should fire after-delete once");

    SystemAssert.assertEquals(1, Database.countQuery("SELECT count() FROM Account"), "merge should leave one row");
    List<ApexSObject> mergedRows = Database.query("SELECT Id, Name FROM Account LIMIT 1");
    SystemAssert.assertEquals(master.id(), mergedRows.get(0).id(), "master id should be retained after merge");
    SystemAssert.assertEquals("Master-Merged-BM", mergedRows.get(0).get("Name"), "merged name mismatch");
    SystemAssert.assertEquals(
        0,
        Database.countQuery("SELECT count() FROM Account WHERE Name IN ('Dup-A', 'Dup-B')"),
        "duplicate rows should be removed from active store");
  }

  @Test
  public void mergeAllOrNoneRollsBackOnFailure() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();
    Database.clearTriggerHandlers();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Master"),
            ApexSObject.of("Account").set("Name", "Duplicate")));

    ApexSObject master = Database.query("SELECT Id, Name FROM Account WHERE Name = 'Master' LIMIT 1").get(0);
    ApexSObject duplicate =
        Database.query("SELECT Id, Name FROM Account WHERE Name = 'Duplicate' LIMIT 1").get(0);

    Database.MergeResult result =
        Database.merge(
            ApexSObject.of("Account").withId(master.id()).set("Name", "Master-Changed"),
            List.of(
                ApexSObject.of("Account").withId(duplicate.id()),
                ApexSObject.of("Account").withId("001xx-missing")),
            true);

    SystemAssert.assertFalse(result.isSuccess(), "merge should fail when one duplicate is missing");
    SystemAssert.assertEquals(
        "INVALID_CROSS_REFERENCE_KEY",
        result.getErrors()[0].getStatusCode(),
        "merge failure status mismatch");
    SystemAssert.assertTrue(
        result.getErrors()[0].getMessage().contains("allOrNone rollback"),
        "merge allOrNone failure should indicate rollback");
    SystemAssert.assertEquals(0, result.getMergedRecordIds().length, "failed merge should not return merged ids");
    SystemAssert.assertEquals(
        0, result.getUpdatedRelatedIds().length, "failed merge should not return updated related ids");
    SystemAssert.assertEquals(
        2,
        Database.countQuery("SELECT count() FROM Account"),
        "failed merge should preserve original row count");
    SystemAssert.assertEquals(
        1,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Master'"),
        "master should keep original value after failed merge");
    SystemAssert.assertEquals(
        0,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Master-Changed'"),
        "master update should be rolled back when merge fails");
  }

  @Test
  public void mergeReparentsRelatedRowsAndReturnsUpdatedRelatedIds() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();
    Database.clearTriggerHandlers();

    final int[] beforeContactUpdate = new int[] {0};
    final int[] afterContactUpdate = new int[] {0};
    Trigger.onBeforeUpdate(
        "Contact",
        () -> {
          beforeContactUpdate[0] += 1;
          SystemAssert.assertEquals(2, Trigger.getOld().size(), "related before-update old size mismatch");
          SystemAssert.assertEquals(2, Trigger.getNew().size(), "related before-update new size mismatch");
          for (Object row : Trigger.getNew()) {
            ApexSObject sobject = (ApexSObject) row;
            sobject.set("LastName", String.valueOf(sobject.get("LastName")) + "-RP");
          }
        });
    Trigger.onAfterUpdate(
        "Contact",
        () -> {
          afterContactUpdate[0] += 1;
          SystemAssert.assertEquals(2, Trigger.getOld().size(), "related after-update old size mismatch");
          SystemAssert.assertEquals(2, Trigger.getNew().size(), "related after-update new size mismatch");
        });

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Master"),
            ApexSObject.of("Account").set("Name", "Duplicate")));

    ApexSObject master = Database.query("SELECT Id, Name FROM Account WHERE Name = 'Master' LIMIT 1").get(0);
    ApexSObject duplicate =
        Database.query("SELECT Id, Name FROM Account WHERE Name = 'Duplicate' LIMIT 1").get(0);

    Database.insert(
        List.of(
            ApexSObject.of("Contact").set("LastName", "A").set("AccountId", duplicate.id()),
            ApexSObject.of("Contact").set("LastName", "B").set("AccountId", duplicate.id()),
            ApexSObject.of("Contact").set("LastName", "M").set("AccountId", master.id())));

    List<ApexSObject> before =
        Database.query("SELECT Id, LastName, AccountId FROM Contact ORDER BY LastName ASC");
    String childAId = before.get(0).id();
    String childBId = before.get(1).id();

    Database.MergeResult result =
        Database.merge(
            ApexSObject.of("Account").withId(master.id()).set("Name", "Master-Keep"),
            ApexSObject.of("Account").withId(duplicate.id()),
            true);

    SystemAssert.assertTrue(result.isSuccess(), "merge with related rows should succeed");
    SystemAssert.assertEquals(1, result.getMergedRecordIds().length, "merged id count mismatch");
    SystemAssert.assertEquals(2, result.getUpdatedRelatedIds().length, "updated related id count mismatch");
    SystemAssert.assertEquals(1, beforeContactUpdate[0], "related before-update should run once");
    SystemAssert.assertEquals(1, afterContactUpdate[0], "related after-update should run once");
    SystemAssert.assertTrue(
        result.getUpdatedRelatedIds()[0].compareToIgnoreCase(result.getUpdatedRelatedIds()[1]) < 0,
        "updated related ids should be returned in stable sorted order");
    SystemAssert.assertTrue(
        result.getUpdatedRelatedIds()[0].equals(childAId)
            || result.getUpdatedRelatedIds()[1].equals(childAId),
        "updated related ids should include child A");
    SystemAssert.assertTrue(
        result.getUpdatedRelatedIds()[0].equals(childBId)
            || result.getUpdatedRelatedIds()[1].equals(childBId),
        "updated related ids should include child B");

    SystemAssert.assertEquals(
        3,
        Database.countQuery("SELECT count() FROM Contact WHERE AccountId = '" + master.id() + "'"),
        "all contacts should point to merged master");
    SystemAssert.assertEquals(
        2,
        Database.countQuery("SELECT count() FROM Contact WHERE LastName LIKE '%-RP'"),
        "related before-update trigger mutations should be persisted");
    SystemAssert.assertEquals(
        0,
        Database.countQuery("SELECT count() FROM Contact WHERE AccountId = '" + duplicate.id() + "'"),
        "duplicate parent id should not remain in related rows");
  }

  @Test
  public void inMemorySObjectStoreSupportsCrudAndQuery() {
    Database.clearInMemoryStore();

    ApexSObject acme = ApexSObject.of("Account").set("Name", "Acme");
    ApexSObject beta = ApexSObject.of("Account").set("Name", "Beta");
    Database.insert(List.of(acme, beta));

    List<ApexSObject> first =
        Database.query("SELECT Id, Name FROM Account WHERE Name = 'Acme' LIMIT 1");
    SystemAssert.assertEquals(1, first.size(), "query should return one row");
    SystemAssert.assertNotNull(first.get(0).id(), "queried row should have generated id");

    ApexSObject row = first.get(0).set("Name", "Acme-Updated");
    Database.update(List.of(row));
    SystemAssert.assertEquals(
        1,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Acme-Updated'"),
        "updated row should be countable");

    Database.delete(List.of(row));
    SystemAssert.assertEquals(
        0,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Acme-Updated'"),
        "deleted row should disappear from active view");

    Database.undelete(List.of(row));
    SystemAssert.assertEquals(
        1,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Acme-Updated'"),
        "undeleted row should return to active view");
  }

  @Test
  public void soqlSupportsAndComparatorsAndOrderBy() {
    Database.clearInMemoryStore();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Alpha").set("Score", 10).set("Tier", 1),
            ApexSObject.of("Account").set("Name", "Beta").set("Score", 30).set("Tier", 2),
            ApexSObject.of("Account").set("Name", "Gamma").set("Score", 20).set("Tier", 2),
            ApexSObject.of("Account").set("Name", "Delta").set("Score", 30).set("Tier", 3)));

    List<ApexSObject> top =
        Database.query(
            "SELECT Id, Name, Score FROM Account "
                + "WHERE Score >= 20 AND Name != 'Gamma' "
                + "ORDER BY Score DESC LIMIT 2");
    SystemAssert.assertEquals(2, top.size(), "top query should return 2 rows");
    SystemAssert.assertEquals("Beta", top.get(0).get("Name"), "first row should be highest score");
    SystemAssert.assertEquals("Delta", top.get(1).get("Name"), "second row should follow score order");

    int narrowCount =
        Database.countQuery("SELECT count() FROM Account WHERE Score < 30 AND Tier = 2 LIMIT 5");
    SystemAssert.assertEquals(1, narrowCount, "count query should support AND + comparators");

    List<ApexSObject> byName =
        Database.query("SELECT Id, Name FROM Account WHERE Score >= 10 ORDER BY Name ASC LIMIT 3");
    SystemAssert.assertEquals("Alpha", byName.get(0).get("Name"), "ASC order should be lexical");
    SystemAssert.assertEquals("Beta", byName.get(1).get("Name"), "ASC order should be lexical");
    SystemAssert.assertEquals("Delta", byName.get(2).get("Name"), "ASC order should be lexical");
  }

  @Test
  public void customSObjectSchemaValidationAndBracketSelectWork() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Schema.object("Invoice__c")
        .required("Name", Schema.FieldType.STRING)
        .required("Amount__c", Schema.FieldType.DECIMAL)
        .optional("Paid__c", Schema.FieldType.BOOLEAN)
        .register();

    Database.SaveResult[] missingRequired =
        Database.insert(List.of(ApexSObject.of("Invoice__c").set("Name", "INV-001")), false);
    SystemAssert.assertFalse(missingRequired[0].isSuccess(), "missing required field should fail");
    SystemAssert.assertEquals(
        "REQUIRED_FIELD_MISSING",
        missingRequired[0].getErrors()[0].getStatusCode(),
        "missing required field status mismatch");
    SystemAssert.assertEquals(
        "Amount__c",
        missingRequired[0].getErrors()[0].getFields()[0],
        "missing required field name mismatch");

    Database.SaveResult[] invalidType =
        Database.insert(
            List.of(
                ApexSObject.of("Invoice__c")
                    .set("Name", "INV-002")
                    .set("Amount__c", "oops")
                    .set("Paid__c", false)),
            false);
    SystemAssert.assertFalse(invalidType[0].isSuccess(), "invalid field type should fail");
    SystemAssert.assertEquals(
        "INVALID_TYPE_ON_FIELD_IN_RECORD",
        invalidType[0].getErrors()[0].getStatusCode(),
        "invalid type status mismatch");

    Database.SaveResult[] valid =
        Database.insert(
            List.of(
                ApexSObject.of("Invoice__c")
                    .set("Name", "INV-003")
                    .set("Amount__c", 1200.0)
                    .set("Paid__c", false)),
            false);
    SystemAssert.assertTrue(valid[0].isSuccess(), "valid custom object row should succeed");

    List<ApexSObject> rows =
        Database.query(
            "[SELECT Id, Name FROM Invoice__c "
                + "WHERE Amount__c >= 1000 AND Paid__c = false "
                + "ORDER BY Name ASC LIMIT 5]");
    SystemAssert.assertEquals(1, rows.size(), "bracket SELECT should be supported");
    SystemAssert.assertEquals("INV-003", rows.get(0).get("Name"), "custom object query mismatch");
  }

  @Test
  public void soqlSupportsInNotInAndLike() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Acme Corp").set("Score", 20),
            ApexSObject.of("Account").set("Name", "Beta Ltd").set("Score", 30),
            ApexSObject.of("Account").set("Name", "Gamma KK").set("Score", 10),
            ApexSObject.of("Account").set("Name", "Acme APAC").set("Score", 25)));

    List<ApexSObject> inRows =
        Database.query(
            "SELECT Id, Name FROM Account "
                + "WHERE Name IN ('Acme Corp', 'Gamma KK') ORDER BY Name ASC LIMIT 5");
    SystemAssert.assertEquals(2, inRows.size(), "IN clause should match two rows");
    SystemAssert.assertEquals("Acme Corp", inRows.get(0).get("Name"), "IN + ORDER BY mismatch");
    SystemAssert.assertEquals("Gamma KK", inRows.get(1).get("Name"), "IN + ORDER BY mismatch");

    int notInCount =
        Database.countQuery("SELECT count() FROM Account WHERE Name NOT IN ('Beta Ltd', 'Gamma KK')");
    SystemAssert.assertEquals(2, notInCount, "NOT IN count mismatch");

    List<ApexSObject> likeRows =
        Database.query(
            "SELECT Id, Name FROM Account "
                + "WHERE Name LIKE 'Acme%' AND Score >= 20 ORDER BY Score DESC LIMIT 2");
    SystemAssert.assertEquals(2, likeRows.size(), "LIKE + AND query should return two rows");
    SystemAssert.assertEquals("Acme APAC", likeRows.get(0).get("Name"), "LIKE result ordering mismatch");
    SystemAssert.assertEquals("Acme Corp", likeRows.get(1).get("Name"), "LIKE result ordering mismatch");
  }

  @Test
  public void soqlSupportsQueryWithBinds() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Acme Core").set("Score", 30).set("Grp", "A"),
            ApexSObject.of("Account").set("Name", "Acme APAC").set("Score", 25).set("Grp", "B"),
            ApexSObject.of("Account").set("Name", "Acme Low").set("Score", 15).set("Grp", "A"),
            ApexSObject.of("Account").set("Name", "Beta").set("Score", 40).set("Grp", "A")));

    Map<String, Object> binds =
        Map.of(
            "minScore", 20,
            "namePattern", "Acme%",
            "groups", List.of("A", "B"),
            "maxRows", 3);

    List<ApexSObject> rows =
        Database.queryWithBinds(
            "SELECT Id, Name, Score FROM Account "
                + "WHERE Score >= :minScore "
                + "AND Name LIKE :namePattern "
                + "AND Grp IN :groups "
                + "ORDER BY Score DESC, Name ASC LIMIT :maxRows",
            binds);
    SystemAssert.assertEquals(2, rows.size(), "bind query should return two rows");
    SystemAssert.assertEquals("Acme Core", rows.get(0).get("Name"), "bind query order mismatch");
    SystemAssert.assertEquals("Acme APAC", rows.get(1).get("Name"), "bind query order mismatch");

    int count =
        Database.countQueryWithBinds(
            "SELECT count() FROM Account WHERE Name IN (:names)",
            Map.of("names", List.of("Acme Core", "Beta")));
    SystemAssert.assertEquals(2, count, "countQueryWithBinds should support list bind in IN clause");
  }

  @Test
  public void soqlQueryWithBindsFailsOnMissingVariable() {
    Database.clearInMemoryStore();

    boolean threw = false;
    try {
      Database.queryWithBinds(
          "SELECT Id, Name FROM Account WHERE Name = :name", Map.of("otherName", "Acme"));
    } catch (IllegalArgumentException expected) {
      threw = true;
      SystemAssert.assertTrue(
          expected.getMessage().contains("missing bind variable :name"),
          "missing bind variable should report name");
    }
    SystemAssert.assertTrue(threw, "queryWithBinds should fail on missing bind variable");
  }

  @Test
  public void soqlQueryWithBindsSupportsMixedQuotesInStringLiteral() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    String quoted = "O'Reilly \"Media\"";
    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", quoted),
            ApexSObject.of("Account").set("Name", "Plain")));

    List<ApexSObject> matched =
        Database.queryWithBinds(
            "SELECT Id, Name FROM Account WHERE Name = :target LIMIT 1",
            Map.of("target", quoted));
    SystemAssert.assertEquals(1, matched.size(), "mixed quote bind should match one row");
    SystemAssert.assertEquals(quoted, matched.get(0).get("Name"), "mixed quote bind value mismatch");

    int count =
        Database.countQueryWithBinds(
            "SELECT count() FROM Account WHERE Name IN :names",
            Map.of("names", List.of(quoted, "Plain")));
    SystemAssert.assertEquals(2, count, "IN bind should include mixed quote value");
  }

  @Test
  public void soqlQueryWithBindsSupportsEmptyInCollection() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Alpha"),
            ApexSObject.of("Account").set("Name", "Beta"),
            ApexSObject.of("Account").set("Name", "Gamma")));

    List<ApexSObject> inRows =
        Database.queryWithBinds(
            "SELECT Id, Name FROM Account WHERE Name IN :names ORDER BY Name ASC",
            Map.of("names", List.of()));
    SystemAssert.assertEquals(0, inRows.size(), "empty IN bind should return no rows");

    int inCount =
        Database.countQueryWithBinds(
            "SELECT count() FROM Account WHERE Name IN (:names)", Map.of("names", List.of()));
    SystemAssert.assertEquals(0, inCount, "empty IN bind count should be zero");

    List<ApexSObject> notInRows =
        Database.queryWithBinds(
            "SELECT Id, Name FROM Account WHERE Name NOT IN :names ORDER BY Name ASC",
            Map.of("names", List.of()));
    SystemAssert.assertEquals(3, notInRows.size(), "empty NOT IN bind should include all rows");
    SystemAssert.assertEquals("Alpha", notInRows.get(0).get("Name"), "empty NOT IN order mismatch");
    SystemAssert.assertEquals("Beta", notInRows.get(1).get("Name"), "empty NOT IN order mismatch");
    SystemAssert.assertEquals("Gamma", notInRows.get(2).get("Name"), "empty NOT IN order mismatch");
  }

  @Test
  public void soqlQueryLocatorSupportsBindsAndIteration() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Acme").set("Score", 30),
            ApexSObject.of("Account").set("Name", "Beta").set("Score", 20),
            ApexSObject.of("Account").set("Name", "Gamma").set("Score", 10)));

    Database.QueryLocator locator =
        Database.getQueryLocator("SELECT Id, Name FROM Account WHERE Score >= 20 ORDER BY Score DESC");
    SystemAssert.assertEquals(2, locator.size(), "query locator should keep filtered row count");

    List<String> iteratedNames = new java.util.ArrayList<>();
    for (ApexSObject row : locator) {
      iteratedNames.add(String.valueOf(row.get("Name")));
    }
    SystemAssert.assertEquals("Acme", iteratedNames.get(0), "locator iteration order mismatch");
    SystemAssert.assertEquals("Beta", iteratedNames.get(1), "locator iteration order mismatch");

    List<ApexSObject> detachedRows = locator.getRecords();
    detachedRows.get(0).set("Name", "MutatedOutside");
    SystemAssert.assertEquals(
        "Acme", locator.getRecords().get(0).get("Name"), "locator rows should be defensive copies");

    Database.QueryLocator boundLocator =
        Database.getQueryLocatorWithBinds(
            "SELECT Id, Name FROM Account WHERE Name IN :names ORDER BY Name ASC",
            Map.of("names", List.of("Beta", "Gamma")));
    SystemAssert.assertEquals(2, boundLocator.size(), "bound locator should support list bind");
    SystemAssert.assertEquals(
        "Beta", boundLocator.getRecords().get(0).get("Name"), "bound locator order mismatch");
    SystemAssert.assertEquals(
        "Gamma", boundLocator.getRecords().get(1).get("Name"), "bound locator order mismatch");
  }

  @Test
  public void soqlSupportsUnaryNot() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Acme Corp").set("Score", 20),
            ApexSObject.of("Account").set("Name", "Beta Ltd").set("Score", 30),
            ApexSObject.of("Account").set("Name", "Gamma KK").set("Score", 10)));

    List<ApexSObject> rows =
        Database.query(
            "SELECT Id, Name FROM Account WHERE NOT (Name LIKE 'Acme%') ORDER BY Name ASC");
    SystemAssert.assertEquals(2, rows.size(), "NOT predicate should filter matching rows");
    SystemAssert.assertEquals("Beta Ltd", rows.get(0).get("Name"), "NOT result mismatch");
    SystemAssert.assertEquals("Gamma KK", rows.get(1).get("Name"), "NOT result mismatch");

    int count =
        Database.countQuery(
            "SELECT count() FROM Account WHERE NOT (Name LIKE 'Acme%') AND NOT (Score < 20)");
    SystemAssert.assertEquals(1, count, "NOT with AND should be supported");

    List<ApexSObject> compound =
        Database.query(
            "SELECT Id, Name FROM Account "
                + "WHERE NOT (Name LIKE 'Acme%' OR Score < 20) "
                + "ORDER BY Name ASC");
    SystemAssert.assertEquals(1, compound.size(), "NOT over OR should be supported");
    SystemAssert.assertEquals("Beta Ltd", compound.get(0).get("Name"), "compound NOT result mismatch");
  }

  @Test
  public void soqlSupportsOrderByNullsFirstLast() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "A-Null").set("Score", null),
            ApexSObject.of("Account").set("Name", "B-Low").set("Score", 10),
            ApexSObject.of("Account").set("Name", "C-Null").set("Score", null),
            ApexSObject.of("Account").set("Name", "D-High").set("Score", 20)));

    Database.NullOrderDefault original = Database.getSoqlNullOrderDefault();
    try {
      Database.setSoqlNullOrderDefault(Database.NullOrderDefault.FIRST);

      List<ApexSObject> defaultAsc =
          Database.query("SELECT Id, Name, Score FROM Account ORDER BY Score ASC, Name ASC");
      SystemAssert.assertEquals("A-Null", defaultAsc.get(0).get("Name"), "default ASC should keep null first");
      SystemAssert.assertEquals("C-Null", defaultAsc.get(1).get("Name"), "default ASC should keep null first");
      SystemAssert.assertEquals("B-Low", defaultAsc.get(2).get("Name"), "default ASC numeric ordering mismatch");
      SystemAssert.assertEquals("D-High", defaultAsc.get(3).get("Name"), "default ASC numeric ordering mismatch");

      List<ApexSObject> defaultDesc =
          Database.query("SELECT Id, Name, Score FROM Account ORDER BY Score DESC, Name ASC");
      SystemAssert.assertEquals("A-Null", defaultDesc.get(0).get("Name"), "default DESC should keep null first");
      SystemAssert.assertEquals("C-Null", defaultDesc.get(1).get("Name"), "default DESC should keep null first");
      SystemAssert.assertEquals("D-High", defaultDesc.get(2).get("Name"), "default DESC numeric ordering mismatch");
      SystemAssert.assertEquals("B-Low", defaultDesc.get(3).get("Name"), "default DESC numeric ordering mismatch");

      List<ApexSObject> first =
          Database.query(
              "SELECT Id, Name, Score FROM Account ORDER BY Score ASC NULLS FIRST, Name ASC");
      SystemAssert.assertEquals(4, first.size(), "NULLS FIRST query size mismatch");
      SystemAssert.assertEquals("A-Null", first.get(0).get("Name"), "NULLS FIRST ordering mismatch");
      SystemAssert.assertEquals("C-Null", first.get(1).get("Name"), "NULLS FIRST ordering mismatch");
      SystemAssert.assertEquals("B-Low", first.get(2).get("Name"), "NULLS FIRST ordering mismatch");
      SystemAssert.assertEquals("D-High", first.get(3).get("Name"), "NULLS FIRST ordering mismatch");

      List<ApexSObject> last =
          Database.query(
              "SELECT Id, Name, Score FROM Account ORDER BY Score DESC NULLS LAST, Name ASC");
      SystemAssert.assertEquals(4, last.size(), "NULLS LAST query size mismatch");
      SystemAssert.assertEquals("D-High", last.get(0).get("Name"), "NULLS LAST ordering mismatch");
      SystemAssert.assertEquals("B-Low", last.get(1).get("Name"), "NULLS LAST ordering mismatch");
      SystemAssert.assertEquals("A-Null", last.get(2).get("Name"), "NULLS LAST ordering mismatch");
      SystemAssert.assertEquals("C-Null", last.get(3).get("Name"), "NULLS LAST ordering mismatch");
    } finally {
      Database.setSoqlNullOrderDefault(original);
    }
  }

  @Test
  public void soqlNullOrderDefaultCanBeConfigured() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "A-Null").set("Score", null),
            ApexSObject.of("Account").set("Name", "B-Low").set("Score", 10),
            ApexSObject.of("Account").set("Name", "C-Null").set("Score", null),
            ApexSObject.of("Account").set("Name", "D-High").set("Score", 20)));

    Database.NullOrderDefault original = Database.getSoqlNullOrderDefault();
    try {
      Database.setSoqlNullOrderDefault(Database.NullOrderDefault.LAST);
      List<ApexSObject> lastMode =
          Database.query("SELECT Id, Name, Score FROM Account ORDER BY Score DESC, Name ASC");
      SystemAssert.assertEquals("D-High", lastMode.get(0).get("Name"), "LAST mode order mismatch");
      SystemAssert.assertEquals("B-Low", lastMode.get(1).get("Name"), "LAST mode order mismatch");
      SystemAssert.assertEquals("A-Null", lastMode.get(2).get("Name"), "LAST mode order mismatch");
      SystemAssert.assertEquals("C-Null", lastMode.get(3).get("Name"), "LAST mode order mismatch");

      Database.setSoqlNullOrderDefault(Database.NullOrderDefault.DIRECTIONAL);
      List<ApexSObject> directionalAsc =
          Database.query("SELECT Id, Name, Score FROM Account ORDER BY Score ASC, Name ASC");
      SystemAssert.assertEquals(
          "A-Null", directionalAsc.get(0).get("Name"), "DIRECTIONAL ASC should keep null first");
      SystemAssert.assertEquals(
          "C-Null", directionalAsc.get(1).get("Name"), "DIRECTIONAL ASC should keep null first");
      List<ApexSObject> directionalDesc =
          Database.query("SELECT Id, Name, Score FROM Account ORDER BY Score DESC, Name ASC");
      SystemAssert.assertEquals(
          "D-High", directionalDesc.get(0).get("Name"), "DIRECTIONAL DESC should keep null last");
      SystemAssert.assertEquals(
          "B-Low", directionalDesc.get(1).get("Name"), "DIRECTIONAL DESC should keep null last");
      SystemAssert.assertEquals(
          "A-Null", directionalDesc.get(2).get("Name"), "DIRECTIONAL DESC should keep null last");
      SystemAssert.assertEquals(
          "C-Null", directionalDesc.get(3).get("Name"), "DIRECTIONAL DESC should keep null last");
    } finally {
      Database.setSoqlNullOrderDefault(original);
    }
  }

  @Test
  public void soqlSupportsOrMultiOrderByAndLikeEscapes() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "alpha_X").set("Score", 30).set("Tier", 2).set("Grp", "A"),
            ApexSObject.of("Account").set("Name", "Alpha%Y").set("Score", 30).set("Tier", 1).set("Grp", "A"),
            ApexSObject.of("Account").set("Name", "beta_x").set("Score", 20).set("Tier", 1).set("Grp", "B"),
            ApexSObject.of("Account").set("Name", "gamma").set("Score", 25).set("Tier", 3).set("Grp", "C")));

    List<ApexSObject> orRows =
        Database.query(
            "SELECT Id, Name FROM Account "
                + "WHERE (Score >= 30 AND Tier = 1) OR Name = 'gamma' "
                + "ORDER BY Name ASC");
    SystemAssert.assertEquals(2, orRows.size(), "OR condition should combine disjoint predicates");
    SystemAssert.assertEquals("Alpha%Y", orRows.get(0).get("Name"), "OR result order mismatch");
    SystemAssert.assertEquals("gamma", orRows.get(1).get("Name"), "OR result order mismatch");

    List<ApexSObject> ordered =
        Database.query(
            "SELECT Id, Name FROM Account "
                + "WHERE Grp IN ('A', 'B') "
                + "ORDER BY Score DESC, Tier ASC, Name DESC");
    SystemAssert.assertEquals(3, ordered.size(), "multi ORDER BY should keep all filtered rows");
    SystemAssert.assertEquals("Alpha%Y", ordered.get(0).get("Name"), "multi ORDER BY key#1 mismatch");
    SystemAssert.assertEquals("alpha_X", ordered.get(1).get("Name"), "multi ORDER BY key#2 mismatch");
    SystemAssert.assertEquals("beta_x", ordered.get(2).get("Name"), "multi ORDER BY key#3 mismatch");

    List<ApexSObject> likeUnderscore =
        Database.query("SELECT Id, Name FROM Account WHERE Name LIKE 'alpha\\_%' ORDER BY Name ASC");
    SystemAssert.assertEquals(1, likeUnderscore.size(), "escaped underscore should be literal");
    SystemAssert.assertEquals("alpha_X", likeUnderscore.get(0).get("Name"), "LIKE underscore escape mismatch");

    List<ApexSObject> likePercent =
        Database.query("SELECT Id, Name FROM Account WHERE Name LIKE 'alpha\\%%' ORDER BY Name ASC");
    SystemAssert.assertEquals(1, likePercent.size(), "escaped percent should be literal");
    SystemAssert.assertEquals("Alpha%Y", likePercent.get(0).get("Name"), "LIKE percent escape mismatch");

    List<ApexSObject> likeCaseInsensitive =
        Database.query("SELECT Id, Name FROM Account WHERE Name LIKE 'ALPHA%' ORDER BY Name ASC LIMIT 2");
    SystemAssert.assertEquals(2, likeCaseInsensitive.size(), "LIKE should be case-insensitive");
  }

  @Test
  public void savepointRollbackRestoresInMemoryStore() {
    Database.clearInMemoryStore();

    ApexSObject seed = ApexSObject.of("Account").set("Name", "Seed");
    Database.insert(List.of(seed));

    Database.Savepoint savepoint = Database.setSavepoint();

    ApexSObject transientRow = ApexSObject.of("Account").set("Name", "Transient");
    Database.insert(List.of(transientRow));
    SystemAssert.assertEquals(
        2, Database.countQuery("SELECT count() FROM Account"), "savepoint branch should add second row");

    ApexSObject loaded = Database.query("SELECT Id, Name FROM Account WHERE Name = 'Seed' LIMIT 1").get(0);
    Database.update(List.of(loaded.set("Name", "Seed-Updated")));
    SystemAssert.assertEquals(
        1,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Seed-Updated'"),
        "update inside savepoint scope should be visible before rollback");

    Database.rollback(savepoint);

    SystemAssert.assertEquals(
        1, Database.countQuery("SELECT count() FROM Account"), "rollback should restore row count");
    SystemAssert.assertEquals(
        1, Database.countQuery("SELECT count() FROM Account WHERE Name = 'Seed'"), "seed should be restored");
    SystemAssert.assertEquals(
        0,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Seed-Updated'"),
        "updated value should be rolled back");
    SystemAssert.assertEquals(
        0,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Transient'"),
        "transient row should be rolled back");
  }

  @Test
  public void saveResultSupportsPartialAndAllOrNone() {
    Database.clearInMemoryStore();

    ApexSObject target = ApexSObject.of("Account").set("Name", "Original");
    Database.insert(List.of(target));

    ApexSObject validPartial = ApexSObject.of("Account").withId(target.id()).set("Name", "Updated-Partial");
    ApexSObject invalidPartial = ApexSObject.of("Account").set("Name", "MissingId");
    Database.SaveResult[] partialResults = Database.update(List.of(validPartial, invalidPartial), false);

    SystemAssert.assertEquals(2, partialResults.length, "partial results size mismatch");
    SystemAssert.assertTrue(partialResults[0].isSuccess(), "first row should succeed in partial mode");
    SystemAssert.assertFalse(partialResults[1].isSuccess(), "second row should fail in partial mode");
    SystemAssert.assertEquals(
        "REQUIRED_FIELD_MISSING",
        partialResults[1].getErrors()[0].getStatusCode(),
        "partial failure status mismatch");
    SystemAssert.assertEquals(
        "Id", partialResults[1].getErrors()[0].getFields()[0], "missing-id failure should point Id field");
    SystemAssert.assertEquals(
        1,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Updated-Partial'"),
        "successful row should be committed in partial mode");

    ApexSObject validAtomic = ApexSObject.of("Account").withId(target.id()).set("Name", "Updated-AllOrNone");
    ApexSObject invalidAtomic = ApexSObject.of("Account").set("Name", "MissingIdAgain");
    Database.SaveResult[] atomicResults = Database.update(List.of(validAtomic, invalidAtomic), true);

    SystemAssert.assertEquals(2, atomicResults.length, "allOrNone results size mismatch");
    SystemAssert.assertFalse(atomicResults[0].isSuccess(), "all rows should fail in allOrNone mode");
    SystemAssert.assertFalse(atomicResults[1].isSuccess(), "all rows should fail in allOrNone mode");
    SystemAssert.assertEquals(
        "REQUIRED_FIELD_MISSING",
        atomicResults[0].getErrors()[0].getStatusCode(),
        "allOrNone should preserve root status code");
    SystemAssert.assertTrue(
        atomicResults[0].getErrors()[0].getMessage().contains("allOrNone rollback"),
        "failure message should indicate rollback");
    SystemAssert.assertEquals(
        1,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Updated-Partial'"),
        "allOrNone rollback should preserve pre-existing committed state");
    SystemAssert.assertEquals(
        0,
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Updated-AllOrNone'"),
        "allOrNone update should not be committed");
  }

  @Test
  public void nestedSavepointRollbackInvalidatesInnerToken() {
    Database.clearInMemoryStore();
    Database.insert(List.of(ApexSObject.of("Account").set("Name", "Base")));

    Database.Savepoint outer = Database.setSavepoint();
    Database.insert(List.of(ApexSObject.of("Account").set("Name", "OuterOnly")));

    Database.Savepoint inner = Database.setSavepoint();
    Database.insert(List.of(ApexSObject.of("Account").set("Name", "InnerOnly")));

    Database.rollback(outer);
    SystemAssert.assertEquals(
        1, Database.countQuery("SELECT count() FROM Account"), "outer rollback should restore base state");

    boolean threw = false;
    try {
      Database.rollback(inner);
    } catch (IllegalArgumentException expected) {
      threw = true;
    }
    SystemAssert.assertTrue(threw, "inner savepoint token should be invalid after outer rollback");
  }

  @Test
  public void dmlCountersTrackStatementsForDatabaseApis() {
    Database.clearInMemoryStore();
    SystemAssert.assertEquals(0, Limits.getDmlStatements(), "fresh test should start at dml=0");

    ApexSObject a = ApexSObject.of("Account").set("Name", "A");
    ApexSObject b = ApexSObject.of("Account").set("Name", "B");
    ApexSObject c = ApexSObject.of("Account").set("Name", "C");
    Database.insert(List.of(a, b, c));
    SystemAssert.assertEquals(1, Limits.getDmlStatements(), "insert(list) should count as one statement");

    List<ApexSObject> rows = Database.query("SELECT Id, Name FROM Account");
    ApexSObject u1 = ApexSObject.of("Account").withId(rows.get(0).id()).set("Name", "A-Updated");
    ApexSObject u2 = ApexSObject.of("Account").withId(rows.get(1).id()).set("Name", "B-Updated");
    Database.update(List.of(u1, u2));
    SystemAssert.assertEquals(2, Limits.getDmlStatements(), "update(list) should count as one statement");

    ApexSObject deleted = ApexSObject.of("Account").withId(rows.get(0).id());
    Database.delete(List.of(deleted));
    Database.undelete(List.of(deleted));
    SystemAssert.assertEquals(
        4, Limits.getDmlStatements(), "delete + undelete should each increment statement count");

    ApexSObject ok = ApexSObject.of("Account").withId(rows.get(2).id()).set("Name", "C-Updated");
    ApexSObject ng = ApexSObject.of("Account").set("Name", "MissingId");
    Database.SaveResult[] partial = Database.update(List.of(ok, ng), false);
    SystemAssert.assertFalse(partial[1].isSuccess(), "partial mode should report per-row failure");
    SystemAssert.assertEquals(5, Limits.getDmlStatements(), "partial update call should count once");

    Database.merge(
        ApexSObject.of("Account").withId(rows.get(0).id()).set("Name", "A-Merged"),
        ApexSObject.of("Account").withId(rows.get(1).id()));
    SystemAssert.assertEquals(6, Limits.getDmlStatements(), "merge should count as one statement");
  }

  private static final class FutureWorker {
    static int executed;

    static void reset() {
      executed = 0;
    }

    @apexemu.annotations.Future
    public static void futureWork() {
      executed += 1;
      ApexDb.cpuBurnMs(2);
    }
  }

  private static final class TriggerRow {
    final String id;
    final String name;

    TriggerRow(String id, String name) {
      this.id = id;
      this.name = name;
    }
  }
}
