/**
 * After insert of Capture__c: publish one Capture_Matching_Request__e per queued capture.
 * The event subscriber runs matching asynchronously as the Automated Process user,
 * so guest-user transactions never create HCPs or consents themselves.
 */
public with sharing class CaptureTriggerHandler {
    @TestVisible
    private static Boolean publishEnabled = true;

    public static void afterInsert(List<Capture__c> captures) {
        if (!publishEnabled) {
            return;
        }
        List<Capture_Matching_Request__e> events = new List<Capture_Matching_Request__e>();
        for (Capture__c c : captures) {
            if (c.Matching_Status__c == CaptureConstants.MATCH_QUEUED) {
                events.add(new Capture_Matching_Request__e(Capture_Id__c = c.Id));
            }
        }
        if (!events.isEmpty()) {
            EventBus.publish(events);
        }
    }

    public static void onMatchingRequests(List<Capture_Matching_Request__e> events) {
        Set<Id> ids = new Set<Id>();
        for (Capture_Matching_Request__e e : events) {
            if (String.isNotBlank(e.Capture_Id__c)) {
                ids.add(Id.valueOf(e.Capture_Id__c));
            }
        }
        CaptureMatchingService.processCaptures(ids);
    }
}
