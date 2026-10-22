trigger CaptureTrigger on Capture__c(after insert) {
    CaptureTriggerHandler.afterInsert(Trigger.new);
}
