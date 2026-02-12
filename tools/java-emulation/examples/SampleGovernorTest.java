package samples;

import apexemu.annotations.Test;
import apexemu.runtime.ApexDb;
import apexemu.runtime.ApexAssert;
import apexemu.runtime.Async;
import apexemu.runtime.ApexSObject;
import apexemu.runtime.ApexStrings;
import apexemu.runtime.BatchContext;
import apexemu.runtime.Database;
import apexemu.runtime.Limits;
import apexemu.runtime.QueryLocatorBatchable;
import apexemu.runtime.Schema;
import apexemu.runtime.SystemAssert;
import apexemu.runtime.Trigger;
import java.time.LocalDate;
import java.time.ZoneOffset;
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
  public void queryLocatorBatchExposesJobAndScopeContext() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "A"),
            ApexSObject.of("Account").set("Name", "B"),
            ApexSObject.of("Account").set("Name", "C"),
            ApexSObject.of("Account").set("Name", "D"),
            ApexSObject.of("Account").set("Name", "E")));

    final String[] startJobId = new String[1];
    final int[] startScopeIndex = new int[1];
    final int[] startTotalScopes = new int[1];
    final int[] startScopeSize = new int[1];
    final int[] startScopeRecordCount = new int[1];
    final BatchContext.Phase[] startPhase = new BatchContext.Phase[1];

    final List<String> executeJobIds = new java.util.ArrayList<>();
    final List<Integer> executeScopeIndexes = new java.util.ArrayList<>();
    final List<Integer> executeTotalScopes = new java.util.ArrayList<>();
    final List<Integer> executeScopeSizes = new java.util.ArrayList<>();
    final List<Integer> executeScopeRecordCounts = new java.util.ArrayList<>();
    final List<BatchContext.Phase> executePhases = new java.util.ArrayList<>();

    final String[] finishJobId = new String[1];
    final int[] finishScopeIndex = new int[1];
    final int[] finishTotalScopes = new int[1];
    final int[] finishScopeSize = new int[1];
    final int[] finishScopeRecordCount = new int[1];
    final BatchContext.Phase[] finishPhase = new BatchContext.Phase[1];

    apexemu.runtime.Test.startTest();
    String jobId =
        Database.executeBatch(
            new QueryLocatorBatchable() {
              @Override
              public Database.QueryLocator start() {
                startJobId[0] = BatchContext.getJobId();
                startScopeIndex[0] = BatchContext.getScopeIndex();
                startTotalScopes[0] = BatchContext.getTotalScopes();
                startScopeSize[0] = BatchContext.getScopeSize();
                startScopeRecordCount[0] = BatchContext.getScopeRecordCount();
                startPhase[0] = BatchContext.getPhase();
                return Database.getQueryLocator("SELECT Id, Name FROM Account ORDER BY Name ASC");
              }

              @Override
              public void execute(List<ApexSObject> scope) {
                executeJobIds.add(BatchContext.getJobId());
                executeScopeIndexes.add(BatchContext.getScopeIndex());
                executeTotalScopes.add(BatchContext.getTotalScopes());
                executeScopeSizes.add(BatchContext.getScopeSize());
                executeScopeRecordCounts.add(BatchContext.getScopeRecordCount());
                executePhases.add(BatchContext.getPhase());
              }

              @Override
              public void finish() {
                finishJobId[0] = BatchContext.getJobId();
                finishScopeIndex[0] = BatchContext.getScopeIndex();
                finishTotalScopes[0] = BatchContext.getTotalScopes();
                finishScopeSize[0] = BatchContext.getScopeSize();
                finishScopeRecordCount[0] = BatchContext.getScopeRecordCount();
                finishPhase[0] = BatchContext.getPhase();
              }
            },
            2);
    apexemu.runtime.Test.stopTest();

    SystemAssert.assertEquals(jobId, startJobId[0], "start should receive same batch job id");
    SystemAssert.assertEquals(0, startScopeIndex[0], "start should have scopeIndex=0");
    SystemAssert.assertEquals(0, startTotalScopes[0], "start should have totalScopes=0 before chunking");
    SystemAssert.assertEquals(2, startScopeSize[0], "start should preserve configured scope size");
    SystemAssert.assertEquals(0, startScopeRecordCount[0], "start should have scopeRecordCount=0");
    SystemAssert.assertEquals(BatchContext.Phase.START, startPhase[0], "start phase mismatch");

    SystemAssert.assertEquals(3, executeJobIds.size(), "execute call count mismatch");
    SystemAssert.assertEquals(jobId, executeJobIds.get(0), "execute #1 job id mismatch");
    SystemAssert.assertEquals(jobId, executeJobIds.get(1), "execute #2 job id mismatch");
    SystemAssert.assertEquals(jobId, executeJobIds.get(2), "execute #3 job id mismatch");
    SystemAssert.assertEquals(1, executeScopeIndexes.get(0), "execute #1 scope index mismatch");
    SystemAssert.assertEquals(2, executeScopeIndexes.get(1), "execute #2 scope index mismatch");
    SystemAssert.assertEquals(3, executeScopeIndexes.get(2), "execute #3 scope index mismatch");
    SystemAssert.assertEquals(3, executeTotalScopes.get(0), "execute #1 total scopes mismatch");
    SystemAssert.assertEquals(3, executeTotalScopes.get(1), "execute #2 total scopes mismatch");
    SystemAssert.assertEquals(3, executeTotalScopes.get(2), "execute #3 total scopes mismatch");
    SystemAssert.assertEquals(2, executeScopeSizes.get(0), "execute #1 scope size mismatch");
    SystemAssert.assertEquals(2, executeScopeSizes.get(1), "execute #2 scope size mismatch");
    SystemAssert.assertEquals(2, executeScopeSizes.get(2), "execute #3 scope size mismatch");
    SystemAssert.assertEquals(2, executeScopeRecordCounts.get(0), "execute #1 record count mismatch");
    SystemAssert.assertEquals(2, executeScopeRecordCounts.get(1), "execute #2 record count mismatch");
    SystemAssert.assertEquals(1, executeScopeRecordCounts.get(2), "execute #3 record count mismatch");
    SystemAssert.assertEquals(BatchContext.Phase.EXECUTE, executePhases.get(0), "execute #1 phase mismatch");
    SystemAssert.assertEquals(BatchContext.Phase.EXECUTE, executePhases.get(1), "execute #2 phase mismatch");
    SystemAssert.assertEquals(BatchContext.Phase.EXECUTE, executePhases.get(2), "execute #3 phase mismatch");

    SystemAssert.assertEquals(jobId, finishJobId[0], "finish should receive same batch job id");
    SystemAssert.assertEquals(0, finishScopeIndex[0], "finish should have scopeIndex=0");
    SystemAssert.assertEquals(3, finishTotalScopes[0], "finish should receive resolved total scopes");
    SystemAssert.assertEquals(2, finishScopeSize[0], "finish should preserve configured scope size");
    SystemAssert.assertEquals(0, finishScopeRecordCount[0], "finish should have scopeRecordCount=0");
    SystemAssert.assertEquals(BatchContext.Phase.FINISH, finishPhase[0], "finish phase mismatch");

    SystemAssert.assertFalse(BatchContext.isExecuting(), "batch context should be cleared after stopTest");
    SystemAssert.assertNull(BatchContext.getJobId(), "batch context job id should be cleared");
    SystemAssert.assertEquals(0, BatchContext.getScopeIndex(), "batch context scope index should reset");
    SystemAssert.assertEquals(0, BatchContext.getTotalScopes(), "batch context total scopes should reset");
    SystemAssert.assertEquals(0, BatchContext.getScopeSize(), "batch context scope size should reset");
    SystemAssert.assertEquals(
        0, BatchContext.getScopeRecordCount(), "batch context scope record count should reset");
    SystemAssert.assertEquals(BatchContext.Phase.NONE, BatchContext.getPhase(), "batch phase should reset");
  }

  @Test
  public void simpleBatchExposesSingleScopeContext() {
    final String[] executeJobId = new String[1];
    final int[] executeScopeIndex = new int[1];
    final int[] executeTotalScopes = new int[1];
    final int[] executeScopeSizeMeta = new int[1];
    final int[] executeScopeRecordCount = new int[1];
    final BatchContext.Phase[] executePhase = new BatchContext.Phase[1];
    final String[] finishJobId = new String[1];
    final int[] finishScopeIndex = new int[1];
    final int[] finishTotalScopes = new int[1];
    final int[] finishScopeSizeMeta = new int[1];
    final int[] finishScopeRecordCount = new int[1];
    final BatchContext.Phase[] finishPhase = new BatchContext.Phase[1];
    final int[] executeScopeSize = new int[1];

    apexemu.runtime.Test.startTest();
    String jobId =
        Database.executeBatch(
            new apexemu.runtime.Batchable() {
              @Override
              public void execute(int scopeSize) {
                executeJobId[0] = BatchContext.getJobId();
                executeScopeIndex[0] = BatchContext.getScopeIndex();
                executeTotalScopes[0] = BatchContext.getTotalScopes();
                executeScopeSizeMeta[0] = BatchContext.getScopeSize();
                executeScopeRecordCount[0] = BatchContext.getScopeRecordCount();
                executePhase[0] = BatchContext.getPhase();
                executeScopeSize[0] = scopeSize;
              }

              @Override
              public void finish() {
                finishJobId[0] = BatchContext.getJobId();
                finishScopeIndex[0] = BatchContext.getScopeIndex();
                finishTotalScopes[0] = BatchContext.getTotalScopes();
                finishScopeSizeMeta[0] = BatchContext.getScopeSize();
                finishScopeRecordCount[0] = BatchContext.getScopeRecordCount();
                finishPhase[0] = BatchContext.getPhase();
              }
            },
            5);
    apexemu.runtime.Test.stopTest();

    SystemAssert.assertEquals(5, executeScopeSize[0], "simple batch should pass configured scope size");
    SystemAssert.assertEquals(jobId, executeJobId[0], "simple batch execute job id mismatch");
    SystemAssert.assertEquals(1, executeScopeIndex[0], "simple batch execute scope index mismatch");
    SystemAssert.assertEquals(1, executeTotalScopes[0], "simple batch execute total scopes mismatch");
    SystemAssert.assertEquals(5, executeScopeSizeMeta[0], "simple batch execute scope size meta mismatch");
    SystemAssert.assertEquals(
        5, executeScopeRecordCount[0], "simple batch execute scope record count mismatch");
    SystemAssert.assertEquals(BatchContext.Phase.EXECUTE, executePhase[0], "simple batch execute phase mismatch");
    SystemAssert.assertEquals(jobId, finishJobId[0], "simple batch finish job id mismatch");
    SystemAssert.assertEquals(0, finishScopeIndex[0], "simple batch finish scope index mismatch");
    SystemAssert.assertEquals(1, finishTotalScopes[0], "simple batch finish total scopes mismatch");
    SystemAssert.assertEquals(5, finishScopeSizeMeta[0], "simple batch finish scope size meta mismatch");
    SystemAssert.assertEquals(0, finishScopeRecordCount[0], "simple batch finish record count mismatch");
    SystemAssert.assertEquals(BatchContext.Phase.FINISH, finishPhase[0], "simple batch finish phase mismatch");
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
  public void soqlSupportsGroupByHavingAggregatesAndOffset() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "A1").set("Tier", "A").set("Score", 10),
            ApexSObject.of("Account").set("Name", "A2").set("Tier", "A").set("Score", 20),
            ApexSObject.of("Account").set("Name", "B1").set("Tier", "B").set("Score", 15),
            ApexSObject.of("Account").set("Name", "B2").set("Tier", "B").set("Score", 35),
            ApexSObject.of("Account").set("Name", "B3").set("Tier", "B").set("Score", null),
            ApexSObject.of("Account").set("Name", "C1").set("Tier", "C").set("Score", null)));

    List<ApexSObject> grouped =
        Database.query(
            "SELECT Tier, COUNT(Id) cnt, SUM(Score) total, AVG(Score) avgScore "
                + "FROM Account GROUP BY Tier HAVING COUNT(Id) >= 2 ORDER BY Tier ASC");
    SystemAssert.assertEquals(2, grouped.size(), "GROUP BY + HAVING should keep A/B only");

    SystemAssert.assertEquals("A", grouped.get(0).get("Tier"), "group row #1 tier mismatch");
    SystemAssert.assertEquals(2L, grouped.get(0).get("cnt"), "group row #1 count mismatch");
    SystemAssert.assertEquals(30.0, grouped.get(0).get("total"), "group row #1 sum mismatch");
    SystemAssert.assertEquals(15.0, grouped.get(0).get("avgScore"), "group row #1 avg mismatch");

    SystemAssert.assertEquals("B", grouped.get(1).get("Tier"), "group row #2 tier mismatch");
    SystemAssert.assertEquals(3L, grouped.get(1).get("cnt"), "group row #2 count mismatch");
    SystemAssert.assertEquals(50.0, grouped.get(1).get("total"), "group row #2 sum mismatch");
    SystemAssert.assertEquals(25.0, grouped.get(1).get("avgScore"), "group row #2 avg mismatch");

    List<ApexSObject> filteredByGroupField =
        Database.query(
            "SELECT Tier, COUNT(Id) cnt "
                + "FROM Account GROUP BY Tier HAVING Tier = 'B' ORDER BY Tier ASC");
    SystemAssert.assertEquals(1, filteredByGroupField.size(), "HAVING on group field should filter tiers");
    SystemAssert.assertEquals("B", filteredByGroupField.get(0).get("Tier"), "HAVING field match mismatch");

    List<ApexSObject> offsetRows =
        Database.query(
            "SELECT Tier, COUNT(Id) cnt "
                + "FROM Account GROUP BY Tier ORDER BY cnt DESC, Tier ASC LIMIT 1 OFFSET 1");
    SystemAssert.assertEquals(1, offsetRows.size(), "OFFSET with aggregate query should be supported");
    SystemAssert.assertEquals("A", offsetRows.get(0).get("Tier"), "OFFSET aggregate ordering mismatch");

    List<ApexSObject> countOnly =
        Database.query("SELECT COUNT() totalRows FROM Account WHERE Score >= 20");
    SystemAssert.assertEquals(1, countOnly.size(), "aggregate without GROUP BY should return one row");
    SystemAssert.assertEquals(2L, countOnly.get(0).get("totalRows"), "COUNT() aggregate mismatch");

    List<ApexSObject> countDistinctByTier =
        Database.query(
            "SELECT Tier, COUNT_DISTINCT(Score) uniqScore "
                + "FROM Account GROUP BY Tier HAVING COUNT_DISTINCT(Score) >= 2 ORDER BY Tier ASC");
    SystemAssert.assertEquals(2, countDistinctByTier.size(), "COUNT_DISTINCT with HAVING should filter groups");
    SystemAssert.assertEquals("A", countDistinctByTier.get(0).get("Tier"), "COUNT_DISTINCT row #1 tier mismatch");
    SystemAssert.assertEquals(2L, countDistinctByTier.get(0).get("uniqScore"), "COUNT_DISTINCT row #1 mismatch");
    SystemAssert.assertEquals("B", countDistinctByTier.get(1).get("Tier"), "COUNT_DISTINCT row #2 tier mismatch");
    SystemAssert.assertEquals(2L, countDistinctByTier.get(1).get("uniqScore"), "COUNT_DISTINCT row #2 mismatch");

    List<ApexSObject> countDistinctTotal =
        Database.query("SELECT COUNT_DISTINCT(Tier) uniqTier FROM Account");
    SystemAssert.assertEquals(1, countDistinctTotal.size(), "aggregate without GROUP BY should return one row");
    SystemAssert.assertEquals(3L, countDistinctTotal.get(0).get("uniqTier"), "COUNT_DISTINCT total mismatch");

    Database.clearInMemoryStore();
    List<ApexSObject> emptyCount = Database.query("SELECT COUNT() totalRows FROM Account");
    SystemAssert.assertEquals(1, emptyCount.size(), "COUNT() on empty table should return one row");
    SystemAssert.assertEquals(0L, emptyCount.get(0).get("totalRows"), "COUNT() on empty table mismatch");
  }

  @Test
  public void soqlSupportsRelativeAndAbsoluteDateLiterals() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    LocalDate today = LocalDate.now(ZoneOffset.UTC);

    Database.insert(
        List.of(
            ApexSObject.of("Task").set("Subject", "past3").set("ActivityDate", today.minusDays(3)),
            ApexSObject.of("Task").set("Subject", "past2").set("ActivityDate", today.minusDays(2)),
            ApexSObject.of("Task").set("Subject", "yesterday").set("ActivityDate", today.minusDays(1)),
            ApexSObject.of("Task").set("Subject", "today").set("ActivityDate", today),
            ApexSObject.of("Task").set("Subject", "tomorrow").set("ActivityDate", today.plusDays(1))));

    List<ApexSObject> todayRows =
        Database.query("SELECT Subject FROM Task WHERE ActivityDate = TODAY ORDER BY Subject ASC");
    SystemAssert.assertEquals(1, todayRows.size(), "TODAY literal should keep only today's row");
    SystemAssert.assertEquals("today", todayRows.get(0).get("Subject"), "TODAY literal row mismatch");

    List<ApexSObject> lastNDaysRows =
        Database.query(
            "SELECT Subject FROM Task WHERE ActivityDate = LAST_N_DAYS:2 ORDER BY ActivityDate ASC");
    SystemAssert.assertEquals(3, lastNDaysRows.size(), "LAST_N_DAYS should include bounded date window");
    SystemAssert.assertEquals("past2", lastNDaysRows.get(0).get("Subject"), "LAST_N_DAYS lower bound mismatch");
    SystemAssert.assertEquals(
        "today", lastNDaysRows.get(2).get("Subject"), "LAST_N_DAYS upper bound mismatch");

    List<ApexSObject> nDaysAgoRows =
        Database.query("SELECT Subject FROM Task WHERE ActivityDate = N_DAYS_AGO:1");
    SystemAssert.assertEquals(1, nDaysAgoRows.size(), "N_DAYS_AGO should match a single day");
    SystemAssert.assertEquals("yesterday", nDaysAgoRows.get(0).get("Subject"), "N_DAYS_AGO row mismatch");

    List<ApexSObject> nextNDaysRows =
        Database.query(
            "SELECT Subject FROM Task WHERE ActivityDate = NEXT_N_DAYS:1 ORDER BY ActivityDate ASC");
    SystemAssert.assertEquals(2, nextNDaysRows.size(), "NEXT_N_DAYS should include today and tomorrow");
    SystemAssert.assertEquals("today", nextNDaysRows.get(0).get("Subject"), "NEXT_N_DAYS lower bound mismatch");
    SystemAssert.assertEquals(
        "tomorrow", nextNDaysRows.get(1).get("Subject"), "NEXT_N_DAYS upper bound mismatch");

    List<ApexSObject> absoluteDateRows =
        Database.query(
            "SELECT Subject FROM Task WHERE ActivityDate >= "
                + today.minusDays(1)
                + " ORDER BY ActivityDate ASC");
    SystemAssert.assertEquals(3, absoluteDateRows.size(), "absolute date literal should support range compare");

    Database.insert(
        List.of(
            ApexSObject.of("Event__c").set("Name", "evtA").set("OccurredAt__c", "2025-03-01T10:15:00Z"),
            ApexSObject.of("Event__c").set("Name", "evtB").set("OccurredAt__c", "2025-03-03T00:00:00Z")));
    List<ApexSObject> isoDatetimeRows =
        Database.query(
            "SELECT Name FROM Event__c WHERE OccurredAt__c >= 2025-03-02 ORDER BY Name ASC");
    SystemAssert.assertEquals(1, isoDatetimeRows.size(), "ISO datetime value should compare with date literal");
    SystemAssert.assertEquals("evtB", isoDatetimeRows.get(0).get("Name"), "ISO datetime comparison mismatch");

    Database.insert(List.of(ApexSObject.of("Milestone__c").set("Name", "strDate").set("DueDate__c", today.toString())));
    List<ApexSObject> stringDateRows =
        Database.query("SELECT Name FROM Milestone__c WHERE DueDate__c = TODAY");
    SystemAssert.assertEquals(1, stringDateRows.size(), "string ISO date should compare with relative literal");
    SystemAssert.assertEquals("strDate", stringDateRows.get(0).get("Name"), "string date literal mismatch");
  }

  @Test
  public void soqlSupportsRelationshipFieldPaths() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    ApexSObject ownerAlice = ApexSObject.of("User").withId("005ALICE").set("Name", "Alice");
    ApexSObject ownerBob = ApexSObject.of("User").withId("005BOB").set("Name", "Bob");
    Database.insert(List.of(ownerAlice, ownerBob));

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Acme").set("OwnerId", "005ALICE"),
            ApexSObject.of("Account").set("Name", "Beta").set("OwnerId", "005BOB"),
            ApexSObject.of("Account").set("Name", "Cloud").set("OwnerId", "005ALICE")));

    List<ApexSObject> aliceOwned =
        Database.query("SELECT Name FROM Account WHERE Owner.Name = 'Alice' ORDER BY Name ASC");
    SystemAssert.assertEquals(2, aliceOwned.size(), "relationship path WHERE should resolve Owner.Name");
    SystemAssert.assertEquals("Acme", aliceOwned.get(0).get("Name"), "Owner.Name filter row #1 mismatch");
    SystemAssert.assertEquals("Cloud", aliceOwned.get(1).get("Name"), "Owner.Name filter row #2 mismatch");

    List<ApexSObject> orderedByOwner =
        Database.query("SELECT Name FROM Account ORDER BY Owner.Name ASC, Name ASC");
    SystemAssert.assertEquals(3, orderedByOwner.size(), "ORDER BY relationship path should be supported");
    SystemAssert.assertEquals("Acme", orderedByOwner.get(0).get("Name"), "ORDER BY Owner.Name row #1 mismatch");
    SystemAssert.assertEquals("Cloud", orderedByOwner.get(1).get("Name"), "ORDER BY Owner.Name row #2 mismatch");
    SystemAssert.assertEquals("Beta", orderedByOwner.get(2).get("Name"), "ORDER BY Owner.Name row #3 mismatch");

    List<ApexSObject> groupedByOwner =
        Database.query(
            "SELECT Owner.Name ownerName, COUNT(Id) cnt "
                + "FROM Account GROUP BY Owner.Name HAVING COUNT(Id) >= 1 ORDER BY ownerName ASC");
    SystemAssert.assertEquals(2, groupedByOwner.size(), "GROUP BY Owner.Name should aggregate by resolved relation");
    SystemAssert.assertEquals("Alice", groupedByOwner.get(0).get("ownerName"), "Owner group #1 label mismatch");
    SystemAssert.assertEquals(2L, groupedByOwner.get(0).get("cnt"), "Owner group #1 count mismatch");
    SystemAssert.assertEquals("Bob", groupedByOwner.get(1).get("ownerName"), "Owner group #2 label mismatch");
    SystemAssert.assertEquals(1L, groupedByOwner.get(1).get("cnt"), "Owner group #2 count mismatch");

    ApexSObject parentA = ApexSObject.of("Parent__c").withId("a00PARENTA").set("Name", "Parent-A");
    ApexSObject parentB = ApexSObject.of("Parent__c").withId("a00PARENTB").set("Name", "Parent-B");
    Database.insert(List.of(parentA, parentB));
    Database.insert(
        List.of(
            ApexSObject.of("Child__c").set("Name", "Child-1").set("Parent__c", "a00PARENTA"),
            ApexSObject.of("Child__c").set("Name", "Child-2").set("Parent__c", "a00PARENTA"),
            ApexSObject.of("Child__c").set("Name", "Child-3").set("Parent__c", "a00PARENTB")));

    List<ApexSObject> parentRows =
        Database.query("SELECT Name FROM Child__c WHERE Parent__r.Name = 'Parent-A' ORDER BY Name ASC");
    SystemAssert.assertEquals(2, parentRows.size(), "custom relationship path WHERE should resolve Parent__r.Name");
    SystemAssert.assertEquals("Child-1", parentRows.get(0).get("Name"), "Parent__r filter row #1 mismatch");
    SystemAssert.assertEquals("Child-2", parentRows.get(1).get("Name"), "Parent__r filter row #2 mismatch");

    List<ApexSObject> groupedByCustomRelation =
        Database.query(
            "SELECT Parent__r.Name parentName, COUNT(Id) cnt "
                + "FROM Child__c GROUP BY Parent__r.Name HAVING Parent__r.Name != 'X' ORDER BY parentName ASC");
    SystemAssert.assertEquals(2, groupedByCustomRelation.size(), "GROUP BY Parent__r.Name should be supported");
    SystemAssert.assertEquals(
        "Parent-A", groupedByCustomRelation.get(0).get("parentName"), "Parent group #1 label mismatch");
    SystemAssert.assertEquals(2L, groupedByCustomRelation.get(0).get("cnt"), "Parent group #1 count mismatch");
    SystemAssert.assertEquals(
        "Parent-B", groupedByCustomRelation.get(1).get("parentName"), "Parent group #2 label mismatch");
    SystemAssert.assertEquals(1L, groupedByCustomRelation.get(1).get("cnt"), "Parent group #2 count mismatch");
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
  public void customSchemaSupportsMaxLengthAndPicklistConstraints() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Schema.object("Invoice__c")
        .required("Name", Schema.FieldType.STRING)
        .maxLength("Name", 8)
        .requiredPicklist("Status__c", "Draft", "Paid")
        .optionalPicklist("Region__c", "JP", "US")
        .register();

    Database.SaveResult[] valid =
        Database.insert(
            List.of(ApexSObject.of("Invoice__c").set("Name", "INV-1001").set("Status__c", "Draft")),
            false);
    SystemAssert.assertTrue(valid[0].isSuccess(), "valid row should pass schema constraints");

    Database.SaveResult[] tooLong =
        Database.insert(
            List.of(ApexSObject.of("Invoice__c").set("Name", "INV-10001").set("Status__c", "Draft")),
            false);
    SystemAssert.assertFalse(tooLong[0].isSuccess(), "max length overflow should fail");
    SystemAssert.assertEquals(
        "STRING_TOO_LONG", tooLong[0].getErrors()[0].getStatusCode(), "max length status mismatch");
    SystemAssert.assertEquals(
        "Name", tooLong[0].getErrors()[0].getFields()[0], "max length error field mismatch");

    Database.SaveResult[] invalidRequiredPicklist =
        Database.insert(
            List.of(ApexSObject.of("Invoice__c").set("Name", "INV-1002").set("Status__c", "Archived")),
            false);
    SystemAssert.assertFalse(
        invalidRequiredPicklist[0].isSuccess(), "restricted required picklist should reject unknown value");
    SystemAssert.assertEquals(
        "INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST",
        invalidRequiredPicklist[0].getErrors()[0].getStatusCode(),
        "required picklist status mismatch");
    SystemAssert.assertEquals(
        "Status__c",
        invalidRequiredPicklist[0].getErrors()[0].getFields()[0],
        "required picklist field mismatch");

    Database.SaveResult[] invalidOptionalPicklist =
        Database.insert(
            List.of(
                ApexSObject.of("Invoice__c")
                    .set("Name", "INV-1003")
                    .set("Status__c", "Paid")
                    .set("Region__c", "EU")),
            false);
    SystemAssert.assertFalse(
        invalidOptionalPicklist[0].isSuccess(), "restricted optional picklist should reject unknown value");
    SystemAssert.assertEquals(
        "INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST",
        invalidOptionalPicklist[0].getErrors()[0].getStatusCode(),
        "optional picklist status mismatch");
    SystemAssert.assertEquals(
        "Region__c",
        invalidOptionalPicklist[0].getErrors()[0].getFields()[0],
        "optional picklist field mismatch");

    SystemAssert.assertEquals(
        1, Database.countQuery("SELECT count() FROM Invoice__c"), "only valid row should be inserted");
  }

  @Test
  public void customSchemaSupportsPrecisionAndLookupReferenceConstraints() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Schema.object("Account").required("Name", Schema.FieldType.STRING).register();
    Schema.object("Invoice__c")
        .required("Name", Schema.FieldType.STRING)
        .required("Amount__c", Schema.FieldType.DECIMAL)
        .precision("Amount__c", 6, 2)
        .optional("Account__c", Schema.FieldType.ID)
        .reference("Account__c", "Account")
        .register();

    Database.SaveResult[] invalidPrecision =
        Database.insert(
            List.of(
                ApexSObject.of("Invoice__c")
                    .set("Name", "INV-PREC")
                    .set("Amount__c", 12345.678)),
            false);
    SystemAssert.assertFalse(invalidPrecision[0].isSuccess(), "precision overflow should fail");
    SystemAssert.assertEquals(
        "NUMBER_OUTSIDE_VALID_RANGE",
        invalidPrecision[0].getErrors()[0].getStatusCode(),
        "precision status mismatch");
    SystemAssert.assertEquals(
        "Amount__c",
        invalidPrecision[0].getErrors()[0].getFields()[0],
        "precision field mismatch");

    Database.SaveResult[] invalidReference =
        Database.insert(
            List.of(
                ApexSObject.of("Invoice__c")
                    .set("Name", "INV-REF")
                    .set("Amount__c", 99.99)
                    .set("Account__c", "001NOREF000000001")),
            false);
    SystemAssert.assertFalse(invalidReference[0].isSuccess(), "lookup reference mismatch should fail");
    SystemAssert.assertEquals(
        "FIELD_INTEGRITY_EXCEPTION",
        invalidReference[0].getErrors()[0].getStatusCode(),
        "lookup status mismatch");
    SystemAssert.assertEquals(
        "Account__c",
        invalidReference[0].getErrors()[0].getFields()[0],
        "lookup field mismatch");

    ApexSObject account = ApexSObject.of("Account").set("Name", "Ref-Account");
    Database.insert(account);

    Database.SaveResult[] valid =
        Database.insert(
            List.of(
                ApexSObject.of("Invoice__c")
                    .set("Name", "INV-OK")
                    .set("Amount__c", 1234.56)
                    .set("Account__c", account.id())),
            false);
    SystemAssert.assertTrue(valid[0].isSuccess(), "valid precision + lookup row should pass");
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
  public void soqlSupportsSemiJoinAndChildSubquery() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    ApexSObject accountA = ApexSObject.of("Account").set("Name", "Acme");
    ApexSObject accountB = ApexSObject.of("Account").set("Name", "Beta");
    ApexSObject accountC = ApexSObject.of("Account").set("Name", "Cloud");
    Database.insert(List.of(accountA, accountB, accountC));

    Database.insert(
        List.of(
            ApexSObject.of("Contact").set("LastName", "Smith").set("AccountId", accountA.id()),
            ApexSObject.of("Contact").set("LastName", "Stone").set("AccountId", accountA.id()),
            ApexSObject.of("Contact").set("LastName", "Tanaka").set("AccountId", accountC.id())));

    List<ApexSObject> semiJoinRows =
        Database.query(
            "SELECT Id, Name FROM Account "
                + "WHERE Id IN (SELECT AccountId FROM Contact WHERE LastName LIKE 'S%') "
                + "ORDER BY Name ASC");
    SystemAssert.assertEquals(1, semiJoinRows.size(), "semi-join should filter parent rows");
    SystemAssert.assertEquals("Acme", semiJoinRows.get(0).get("Name"), "semi-join row mismatch");

    int notInCount =
        Database.countQuery(
            "SELECT count() FROM Account WHERE Id NOT IN (SELECT AccountId FROM Contact)");
    SystemAssert.assertEquals(1, notInCount, "NOT IN semi-join should keep only unrelated parents");

    List<ApexSObject> parentWithChildren =
        Database.query(
            "SELECT Id, Name, (SELECT Id, LastName FROM Contacts WHERE LastName LIKE 'S%' ORDER BY LastName ASC) "
                + "FROM Account ORDER BY Name ASC");
    SystemAssert.assertEquals(3, parentWithChildren.size(), "child subquery should keep parent cardinality");

    @SuppressWarnings("unchecked")
    List<ApexSObject> acmeChildren = (List<ApexSObject>) parentWithChildren.get(0).get("Contacts");
    SystemAssert.assertEquals(2, acmeChildren.size(), "Acme should contain filtered child rows");
    SystemAssert.assertEquals("Smith", acmeChildren.get(0).get("LastName"), "child sort mismatch");
    SystemAssert.assertEquals("Stone", acmeChildren.get(1).get("LastName"), "child sort mismatch");

    @SuppressWarnings("unchecked")
    List<ApexSObject> betaChildren = (List<ApexSObject>) parentWithChildren.get(1).get("Contacts");
    SystemAssert.assertEquals(0, betaChildren.size(), "Beta should have empty child rows");
  }

  @Test
  public void soqlSupportsIsNullAndIsNotNull() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "A-Null").set("Score", null),
            ApexSObject.of("Account").set("Name", "B-Low").set("Score", 10),
            ApexSObject.of("Account").set("Name", "C-Null").set("Score", null),
            ApexSObject.of("Account").set("Name", "D-High").set("Score", 30)));

    List<ApexSObject> nullRows =
        Database.query("SELECT Id, Name FROM Account WHERE Score IS NULL ORDER BY Name ASC");
    SystemAssert.assertEquals(2, nullRows.size(), "IS NULL should match null-valued rows");
    SystemAssert.assertEquals("A-Null", nullRows.get(0).get("Name"), "IS NULL row #1 mismatch");
    SystemAssert.assertEquals("C-Null", nullRows.get(1).get("Name"), "IS NULL row #2 mismatch");

    int nonNullCount = Database.countQuery("SELECT count() FROM Account WHERE Score IS NOT NULL");
    SystemAssert.assertEquals(2, nonNullCount, "IS NOT NULL should match non-null rows");

    List<ApexSObject> unaryNotRows =
        Database.query("SELECT Id, Name FROM Account WHERE NOT (Score IS NULL) ORDER BY Score DESC");
    SystemAssert.assertEquals(2, unaryNotRows.size(), "NOT (IS NULL) should be supported");
    SystemAssert.assertEquals("D-High", unaryNotRows.get(0).get("Name"), "NOT (IS NULL) row #1 mismatch");
    SystemAssert.assertEquals("B-Low", unaryNotRows.get(1).get("Name"), "NOT (IS NULL) row #2 mismatch");
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
  public void soqlIgnoresTrailingRowLockingModifiers() {
    Database.clearInMemoryStore();
    Database.clearSchemaRegistry();

    Database.insert(
        List.of(
            ApexSObject.of("Account").set("Name", "Locking"),
            ApexSObject.of("Account").set("Name", "Another")));

    List<ApexSObject> forUpdate =
        Database.query("SELECT Id, Name FROM Account WHERE Name = 'Locking' FOR UPDATE");
    SystemAssert.assertEquals(1, forUpdate.size(), "FOR UPDATE should be tolerated in emulation");

    int allRowsCount =
        Database.countQuery("SELECT count() FROM Account WHERE Name = 'Locking' ALL ROWS");
    SystemAssert.assertEquals(1, allRowsCount, "ALL ROWS should be tolerated in countQuery");

    List<ApexSObject> forViewRows =
        Database.queryWithBinds(
            "SELECT Id, Name FROM Account WHERE Name = :name FOR VIEW", Map.of("name", "Locking"));
    SystemAssert.assertEquals(1, forViewRows.size(), "FOR VIEW should be tolerated with binds");

    Database.QueryLocator locator =
        Database.getQueryLocatorWithBinds(
            "SELECT Id, Name FROM Account WHERE Name = :name FOR REFERENCE",
            Map.of("name", "Locking"));
    SystemAssert.assertEquals(
        1, locator.size(), "FOR REFERENCE should be tolerated in query locator with binds");
  }

  @Test
  public void apexStringsHelpersSupportCommonApexPatterns() {
    SystemAssert.assertTrue(ApexStrings.isBlank(" "), "isBlank should treat spaces as blank");
    SystemAssert.assertTrue(ApexStrings.isNotBlank("Acme"), "isNotBlank should detect text");
    SystemAssert.assertTrue(ApexStrings.isEmpty(""), "isEmpty should detect empty string");
    SystemAssert.assertTrue(ApexStrings.isNotEmpty("x"), "isNotEmpty should detect non-empty");

    String joined = ApexStrings.join(List.of("A", "B", "C"), ",");
    SystemAssert.assertEquals("A,B,C", joined, "join should follow Apex list+separator order");

    String escaped = ApexStrings.escapeSingleQuotes("O'Reilly");
    SystemAssert.assertEquals("O\\'Reilly", escaped, "escapeSingleQuotes should backslash apostrophes");
  }

  @Test
  public void apexAssertSupportsAssertClassStyleApis() {
    ApexAssert.isTrue(true, "isTrue should pass");
    ApexAssert.isFalse(false, "isFalse should pass");
    ApexAssert.areEqual("A", "A", "areEqual should pass");
    ApexAssert.areNotEqual("A", "B", "areNotEqual should pass");
    ApexAssert.isNull(null, "isNull should pass");
    ApexAssert.isNotNull("x", "isNotNull should pass");
    ApexAssert.isInstanceOfType("x", String.class, "String instance check should pass");
    ApexAssert.isNotInstanceOfType("x", Integer.class, "negative class instance check should pass");

    ApexSObject account = ApexSObject.of("Account").set("Name", "Acme");
    ApexAssert.isInstanceOfType(account, "Account", "sobject type-name check should pass");
    ApexAssert.isNotInstanceOfType(account, "Contact", "sobject negative type-name check should pass");

    boolean failed = false;
    try {
      ApexAssert.fail("forced failure");
    } catch (AssertionError expected) {
      failed = true;
      SystemAssert.assertTrue(
          expected.getMessage().contains("forced failure"), "fail should keep message");
    }
    SystemAssert.assertTrue(failed, "ApexAssert.fail should throw AssertionError");

    boolean instanceFailed = false;
    try {
      ApexAssert.isInstanceOfType(account, "Contact", "expected failure");
    } catch (AssertionError expected) {
      instanceFailed = true;
      SystemAssert.assertTrue(
          expected.getMessage().contains("expected failure"),
          "isInstanceOfType failure should keep message");
    }
    SystemAssert.assertTrue(instanceFailed, "isInstanceOfType mismatch should throw");

    boolean notInstanceFailed = false;
    try {
      ApexAssert.isNotInstanceOfType(account, "Account", "expected failure");
    } catch (AssertionError expected) {
      notInstanceFailed = true;
      SystemAssert.assertTrue(
          expected.getMessage().contains("expected failure"),
          "isNotInstanceOfType failure should keep message");
    }
    SystemAssert.assertTrue(notInstanceFailed, "isNotInstanceOfType mismatch should throw");
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
