package samples;

import apexemu.annotations.Test;
import apexemu.runtime.ApexDb;
import apexemu.runtime.Async;
import apexemu.runtime.ApexSObject;
import apexemu.runtime.Database;
import apexemu.runtime.Limits;
import apexemu.runtime.SystemAssert;
import apexemu.runtime.Trigger;
import java.util.List;

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
        "DML_ERROR", partialResults[1].getErrors()[0].getStatusCode(), "partial failure status mismatch");
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
