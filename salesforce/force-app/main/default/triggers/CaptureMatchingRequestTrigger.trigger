trigger CaptureMatchingRequestTrigger on Capture_Matching_Request__e(after insert) {
    CaptureTriggerHandler.onMatchingRequests(Trigger.new);
}
