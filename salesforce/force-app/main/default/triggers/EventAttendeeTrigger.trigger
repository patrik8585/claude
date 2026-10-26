/**
 * Attendance Status says where the HCP is now (Registered -> Attended at check-in); Registered__c remembers
 * that the HCP had registered before the event, so after check-in "registered and checked in" can still be
 * told from a walk-in. The flag is set by the system: any attendee entered or set as Registered gets it.
 */
trigger EventAttendeeTrigger on Event_Attendee__c(before insert, before update) {
    for (Event_Attendee__c a : Trigger.new) {
        if (a.Attendance_Status__c == CaptureConstants.ATTENDANCE_REGISTERED) {
            a.Registered__c = true;
        }
    }
}
