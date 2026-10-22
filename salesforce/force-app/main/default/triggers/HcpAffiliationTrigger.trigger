trigger HcpAffiliationTrigger on HCP_Affiliation__c(before insert, before update, after insert, after update, after delete) {
    if (Trigger.isBefore) {
        AffiliationService.beforeSave(Trigger.new);
    } else if (Trigger.isDelete) {
        AffiliationService.afterDelete(Trigger.old);
    } else {
        AffiliationService.afterSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    }
}
