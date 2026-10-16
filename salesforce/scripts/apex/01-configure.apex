// 1) Settings + random form secret. Replace the URL with your public site URL
//    (Setup > Digital Experiences > All Sites > URL of the "hcp" site). You can re-run this later.
ConsentDemoData.configure('https://REPLACE-ME.my.site.com/hcp');
System.debug(Consent_Capture_Settings__c.getOrgDefaults());
