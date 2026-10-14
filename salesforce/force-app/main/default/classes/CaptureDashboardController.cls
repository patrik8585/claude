/**
 * Data for the "Capture performance" dashboard LWC (mockup step 7), filterable by event.
 * The same figures are available as standard reports (force-app-extras).
 */
public with sharing class CaptureDashboardController {
    public class Bucket {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public Integer value;
        public Bucket(String label, Integer value) {
            this.label = label;
            this.value = value;
        }
    }

    public class Stats {
        @AuraEnabled
        public Integer total;
        @AuraEnabled
        public List<Bucket> byChannel;
        @AuraEnabled
        public List<Bucket> byRep;
        @AuraEnabled
        public List<Bucket> matching;
        @AuraEnabled
        public List<Bucket> consent;
        /** Pre-event registrations and how many of them attended. */
        @AuraEnabled
        public Integer registered;
        @AuraEnabled
        public Integer checkedIn;
    }

    @AuraEnabled
    public static Stats getStats(String eventId) {
        Id evId = String.isBlank(eventId) ? null : Id.valueOf(eventId);
        Stats s = new Stats();
        s.total = 0;
        Map<String, Integer> channel = new Map<String, Integer>{
            CaptureConstants.CHANNEL_SELF => 0,
            CaptureConstants.CHANNEL_REP => 0,
            CaptureConstants.CHANNEL_KIOSK => 0
        };
        Map<String, Integer> matching = new Map<String, Integer>{
            'Auto-matched' => 0,
            'Reviewed by data steward' => 0,
            'New HCP (auto-created)' => 0,
            'Waiting for review' => 0,
            'Discarded' => 0,
            'Queued / error' => 0
        };
        Map<String, Integer> consent = new Map<String, Integer>{ 'Confirmed' => 0, 'Pending confirmation' => 0, 'Declined' => 0 };
        Map<String, Integer> reps = new Map<String, Integer>();

        List<AggregateResult> rows = evId == null
            ? [
                  SELECT Channel__c ch, Matching_Status__c ms, Opt_In_Status__c os, Captured_By_Name__c rep, COUNT(Id) n
                  FROM Capture__c
                  WHERE Channel__c != :CaptureConstants.CHANNEL_REGISTRATION
                  GROUP BY Channel__c, Matching_Status__c, Opt_In_Status__c, Captured_By_Name__c
              ]
            : [
                  SELECT Channel__c ch, Matching_Status__c ms, Opt_In_Status__c os, Captured_By_Name__c rep, COUNT(Id) n
                  FROM Capture__c
                  WHERE Event__c = :evId AND Channel__c != :CaptureConstants.CHANNEL_REGISTRATION
                  GROUP BY Channel__c, Matching_Status__c, Opt_In_Status__c, Captured_By_Name__c
              ];
        for (AggregateResult ar : rows) {
            Integer n = (Integer) ar.get('n');
            String ch = (String) ar.get('ch');
            String ms = (String) ar.get('ms');
            String os = (String) ar.get('os');
            String rep = (String) ar.get('rep');
            s.total += n;
            if (ch != null && channel.containsKey(ch)) {
                channel.put(ch, channel.get(ch) + n);
            }
            String mk = matchingBucket(ms);
            matching.put(mk, matching.get(mk) + n);
            String ck = os == CaptureConstants.OPTIN_CONFIRMED ? 'Confirmed' : (os == CaptureConstants.OPTIN_DECLINED ? 'Declined' : 'Pending confirmation');
            consent.put(ck, consent.get(ck) + n);
            if (ch == CaptureConstants.CHANNEL_REP && String.isNotBlank(rep)) {
                reps.put(rep, (reps.containsKey(rep) ? reps.get(rep) : 0) + n);
            }
        }
        s.byChannel = toBuckets(channel);
        s.matching = toBuckets(matching);
        s.consent = toBuckets(consent);
        s.byRep = toBuckets(reps);
        // Registrations are imported before the event: counted apart, not as captures.
        s.registered = 0;
        s.checkedIn = 0;
        List<AggregateResult> att = evId == null
            ? [SELECT Attendance_Status__c st, COUNT(Id) n FROM Event_Attendee__c WHERE Registered__c = TRUE GROUP BY Attendance_Status__c]
            : [
                  SELECT Attendance_Status__c st, COUNT(Id) n
                  FROM Event_Attendee__c
                  WHERE Registered__c = TRUE AND Event__c = :evId
                  GROUP BY Attendance_Status__c
              ];
        for (AggregateResult ar : att) {
            Integer n = (Integer) ar.get('n');
            s.registered += n;
            if ((String) ar.get('st') == CaptureConstants.ATTENDANCE_ATTENDED) {
                s.checkedIn += n;
            }
        }
        return s;
    }

    @AuraEnabled
    public static List<Map<String, String>> getEvents() {
        List<Map<String, String>> out = new List<Map<String, String>>();
        for (Event__c ev : [SELECT Id, Name FROM Event__c ORDER BY Start_Date__c DESC NULLS LAST LIMIT 50]) {
            out.add(new Map<String, String>{ 'value' => ev.Id, 'label' => ev.Name });
        }
        return out;
    }

    private static String matchingBucket(String status) {
        if (status == CaptureConstants.MATCH_AUTO) {
            return 'Auto-matched';
        }
        if (status == CaptureConstants.MATCH_REVIEWED || status == CaptureConstants.MATCH_REVIEWED_NEW) {
            return 'Reviewed by data steward';
        }
        if (status == CaptureConstants.MATCH_NEW) {
            return 'New HCP (auto-created)';
        }
        if (status == CaptureConstants.MATCH_REVIEW) {
            return 'Waiting for review';
        }
        if (status == CaptureConstants.MATCH_DISCARDED) {
            return 'Discarded';
        }
        return 'Queued / error';
    }

    private static List<Bucket> toBuckets(Map<String, Integer> m) {
        List<Bucket> out = new List<Bucket>();
        for (String k : m.keySet()) {
            out.add(new Bucket(k, m.get(k)));
        }
        return out;
    }
}
