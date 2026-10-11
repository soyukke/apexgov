trigger AccountValidation on Account (after insert, after update) {
    if (Trigger.isAfter) {
        GovernorRiskService.run(Trigger.new);
        BulkSafeService.process(Trigger.new);
    }
}
