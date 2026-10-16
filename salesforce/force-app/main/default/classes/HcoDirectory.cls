/**
 * Hospitals and departments (Account record types Hospital / Department), cached per transaction.
 * Resolves the free-text organisation or the email domain of a capture to a hospital, and picks
 * the department of a hospital that fits a specialty.
 */
public without sharing class HcoDirectory {
    public static final String RT_HOSPITAL = 'Hospital';
    public static final String RT_DEPARTMENT = 'Department';

    /** Department type -> HCP specialty (global value set HCP_Specialty). */
    public static final Map<String, String> SPECIALTY_BY_DEPARTMENT = new Map<String, String>{
        'Paediatrics' => 'Paediatrics',
        'Neonatology' => 'Neonatology',
        'Neonatal Intensive Care' => 'Neonatology',
        'Paediatric Gastroenterology' => 'Paediatric Gastroenterology',
        'Paediatric Allergy' => 'Paediatric Allergy',
        'Paediatric Emergency' => 'Paediatrics',
        'Obstetrics & Gynaecology' => 'Gynaecology',
        'Clinical Nutrition' => 'Dietetics & Nutrition',
        'Paediatric Endocrinology' => 'Paediatrics',
        'Paediatric Surgery' => 'Paediatrics'
    };

    public class Resolution {
        public Id hospitalId;
        public String reason;
    }

    private static HcoDirectory instance;

    public Map<Id, Account> hospitals = new Map<Id, Account>();
    public Map<Id, Account> departments = new Map<Id, Account>();
    public Map<Id, List<Account>> departmentsByHospital = new Map<Id, List<Account>>();
    private Map<String, Set<Id>> hospitalsByDomain = new Map<String, Set<Id>>();
    private Map<Id, List<String>> namesByHospital = new Map<Id, List<String>>();

    public static HcoDirectory get() {
        if (instance == null) {
            instance = new HcoDirectory();
        }
        return instance;
    }

    /** Call after inserting hospitals/departments in the same transaction. */
    public static void reset() {
        instance = null;
    }

    public static Id recordTypeId(String developerName) {
        Schema.RecordTypeInfo info = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get(developerName);
        return info == null ? null : info.getRecordTypeId();
    }

    private HcoDirectory() {
        for (Account a : [
            SELECT Id, Name, ParentId, BillingCity, Email_Domain__c, Aliases__c, Department_Type__c, RecordType.DeveloperName
            FROM Account
            WHERE RecordType.DeveloperName IN (:RT_HOSPITAL, :RT_DEPARTMENT)
            ORDER BY Name
            LIMIT 10000
        ]) {
            if (a.RecordType.DeveloperName == RT_HOSPITAL) {
                hospitals.put(a.Id, a);
            } else {
                departments.put(a.Id, a);
            }
        }
        for (Account d : departments.values()) {
            if (d.ParentId != null) {
                if (!departmentsByHospital.containsKey(d.ParentId)) {
                    departmentsByHospital.put(d.ParentId, new List<Account>());
                }
                departmentsByHospital.get(d.ParentId).add(d);
            }
        }
        for (Account h : hospitals.values()) {
            List<String> names = new List<String>{ HcpMatchEngine.normalize(h.Name) };
            if (String.isNotBlank(h.Aliases__c)) {
                for (String alias : h.Aliases__c.split(';')) {
                    String n = HcpMatchEngine.normalize(alias);
                    if (n.length() >= 4) {
                        names.add(n);
                    }
                }
            }
            namesByHospital.put(h.Id, names);
            if (String.isNotBlank(h.Email_Domain__c)) {
                for (String dom : h.Email_Domain__c.split('[,;\\s]+')) {
                    String k = dom.trim().toLowerCase().removeStart('@');
                    if (String.isNotBlank(k)) {
                        if (!hospitalsByDomain.containsKey(k)) {
                            hospitalsByDomain.put(k, new Set<Id>());
                        }
                        hospitalsByDomain.get(k).add(h.Id);
                    }
                }
            }
        }
    }

    /** The hospital of an HCO: itself for a hospital, the parent for a department, null otherwise. */
    public Id hospitalOf(Id hcoId) {
        if (hcoId == null) {
            return null;
        }
        if (hospitals.containsKey(hcoId)) {
            return hcoId;
        }
        Account d = departments.get(hcoId);
        return d == null ? null : d.ParentId;
    }

    public Boolean isDepartment(Id hcoId) {
        return hcoId != null && departments.containsKey(hcoId);
    }

    public String hospitalName(Id hospitalId) {
        Account h = hospitals.get(hospitalId);
        return h == null ? null : h.Name;
    }

    /** "Paediatrics - Gaslini Institute" style label for a department or hospital. */
    public String label(Id hcoId) {
        if (hcoId == null) {
            return null;
        }
        if (hospitals.containsKey(hcoId)) {
            return hospitals.get(hcoId).Name;
        }
        Account d = departments.get(hcoId);
        if (d == null) {
            return null;
        }
        String h = hospitalName(d.ParentId);
        String deptType = String.isBlank(d.Department_Type__c) ? d.Name : d.Department_Type__c;
        return h == null ? deptType : deptType + ' - ' + h;
    }

    /**
     * Hospital from the captured organisation text (name or alias, accent-insensitive) or,
     * failing that, from an institutional email domain. Ambiguous text (several hospitals) resolves to nothing.
     */
    public Resolution resolve(String organisation, String email) {
        Resolution r = new Resolution();
        String org = HcpMatchEngine.normalize(organisation);
        if (org.length() >= 4) {
            Id best;
            Integer bestLen = 0;
            Boolean tie = false;
            for (Id hid : namesByHospital.keySet()) {
                for (String n : namesByHospital.get(hid)) {
                    Boolean hit = org == n || org.contains(n) || (org.length() >= 5 && n.contains(org));
                    if (!hit) {
                        continue;
                    }
                    Integer len = Math.min(org.length(), n.length());
                    if (len > bestLen) {
                        best = hid;
                        bestLen = len;
                        tie = false;
                    } else if (len == bestLen && hid != best) {
                        tie = true;
                    }
                }
            }
            if (best != null && !tie) {
                r.hospitalId = best;
                r.reason = 'organisation "' + organisation.trim() + '"';
                return r;
            }
        }
        String domain = HcpMatchEngine.emailDomain(email);
        if (String.isNotBlank(domain) && !MatchingConfig.get().isPersonalDomain(domain)) {
            Set<Id> ids = hospitalsByDomain.get(domain);
            if (ids != null && ids.size() == 1) {
                r.hospitalId = new List<Id>(ids)[0];
                r.reason = 'email domain ' + domain;
            }
        }
        return r;
    }

    /** Department of the hospital whose type fits the specialty (first by name), or null. */
    public Id departmentFor(Id hospitalId, String specialty) {
        if (hospitalId == null || String.isBlank(specialty) || !departmentsByHospital.containsKey(hospitalId)) {
            return null;
        }
        for (Account d : departmentsByHospital.get(hospitalId)) {
            if (d.Department_Type__c == specialty) {
                return d.Id;
            }
        }
        for (Account d : departmentsByHospital.get(hospitalId)) {
            if (SPECIALTY_BY_DEPARTMENT.get(d.Department_Type__c) == specialty) {
                return d.Id;
            }
        }
        return null;
    }
}
