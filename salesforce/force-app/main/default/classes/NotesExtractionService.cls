/**
 * Phase 1 "Extract with AI": simple rule-based extraction from the rep's (dictated) notes,
 * mirroring the mockup. Phase 3 replaces extract() with a Prompt Builder template call
 * returning the same Result structure, so the LWC does not change.
 */
public with sharing class NotesExtractionService {
    public class Result {
        @AuraEnabled
        public String firstName;
        @AuraEnabled
        public String lastName;
        @AuraEnabled
        public String email;
        @AuraEnabled
        public String specialty;
        @AuraEnabled
        public String city;
        @AuraEnabled
        public String organisation;
        @AuraEnabled
        public String interest;
        @AuraEnabled
        public String taskTitle;
        @AuraEnabled
        public Date taskDueDate;
        @AuraEnabled
        public String taskDueLabel;
        @AuraEnabled
        public Integer fieldCount;
        @AuraEnabled
        public List<String> chips;
    }

    private static final List<List<String>> SPECIALTY_KEYWORDS = new List<List<String>>{
        new List<String>{ 'paediatrician', 'Paediatrics' },
        new List<String>{ 'pediatrician', 'Paediatrics' },
        new List<String>{ 'pediatra', 'Paediatrics' },
        new List<String>{ 'neonatolog', 'Neonatology' },
        new List<String>{ 'gastroenterolog', 'Paediatric Gastroenterology' },
        new List<String>{ 'allergolog', 'Paediatric Allergy' },
        new List<String>{ 'dietitian', 'Dietetics & Nutrition' },
        new List<String>{ 'nutrizionist', 'Dietetics & Nutrition' },
        new List<String>{ 'gynaecolog', 'Gynaecology' },
        new List<String>{ 'ginecolog', 'Gynaecology' }
    };

    private static final Map<String, String> CITIES = new Map<String, String>{
        'Genoa' => 'Genoa', 'Genova' => 'Genoa',
        'Milan' => 'Milan', 'Milano' => 'Milan',
        'Rome' => 'Rome', 'Roma' => 'Rome',
        'Naples' => 'Naples', 'Napoli' => 'Naples',
        'Turin' => 'Turin', 'Torino' => 'Turin',
        'Bologna' => 'Bologna',
        'Florence' => 'Florence', 'Firenze' => 'Florence',
        'Padua' => 'Padua', 'Padova' => 'Padua',
        'Verona' => 'Verona',
        'Bergamo' => 'Bergamo',
        'Brescia' => 'Brescia'
    };

    private static final List<String> MONTHS = new List<String>{
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
    };
    private static final List<String> DAY_NAMES = new List<String>{ 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun' };

    public static Result extract(String notes) {
        return extract(notes, Date.today());
    }

    @TestVisible
    private static Result extract(String notes, Date today) {
        Result r = new Result();
        r.chips = new List<String>();
        r.fieldCount = 0;
        if (String.isBlank(notes)) {
            return r;
        }
        String t = notes.left(5000);
        String lower = t.toLowerCase();

        Matcher m = Pattern.compile('Dr\\.?\\s+([A-ZÀ-Ý][\\wà-ÿ\'’-]+)(?:\\s+([A-ZÀ-Ý][\\wà-ÿ\'’-]+))?').matcher(t);
        if (m.find()) {
            if (m.group(2) != null) {
                r.firstName = m.group(1);
                r.lastName = m.group(2);
            } else {
                r.lastName = m.group(1);
            }
        }
        Matcher em = Pattern.compile('[\\w.+-]+@[\\w-]+\\.[\\w.]+').matcher(t);
        if (em.find()) {
            r.email = em.group(0).removeEnd('.');
        }
        for (List<String> kv : SPECIALTY_KEYWORDS) {
            if (lower.contains(kv[0])) {
                r.specialty = kv[1];
                break;
            }
        }
        for (String c : CITIES.keySet()) {
            if (Pattern.compile('\\b' + c + '\\b').matcher(t).find()) {
                r.city = CITIES.get(c);
                break;
            }
        }
        Matcher om = Pattern.compile('\\bat\\s+([A-Z][\\wà-ÿ]+)').matcher(t);
        if (om.find()) {
            r.organisation = om.group(1);
        }
        Matcher pm = Pattern.compile('(?i)product\\s+([A-Z0-9][\\w-]*)').matcher(t);
        if (pm.find()) {
            r.interest = 'Product ' + pm.group(1);
        }

        String person = 'Dr. ' + ((r.firstName == null ? '' : r.firstName + ' ') + (r.lastName == null ? '' : r.lastName)).trim();
        Integer monthIdx = -1;
        for (Integer i = 0; i < MONTHS.size(); i++) {
            if (lower.contains('call back in ' + MONTHS[i].toLowerCase())) {
                monthIdx = i + 1;
                break;
            }
        }
        if (monthIdx > 0) {
            r.taskTitle = 'Call back ' + person;
            r.taskDueDate = firstMondayOf(monthIdx, today);
            r.taskDueLabel = label(r.taskDueDate);
        } else {
            r.taskTitle = 'Follow up with ' + person;
            r.taskDueDate = today.addDays(14);
            r.taskDueLabel = 'Within 2 weeks';
        }

        addChip(r, 'First name', r.firstName);
        addChip(r, 'Last name', r.lastName);
        addChip(r, 'Email', r.email);
        addChip(r, 'Specialty', r.specialty);
        addChip(r, 'City', r.city);
        addChip(r, 'Hospital', r.organisation);
        addChip(r, 'Interest', r.interest);
        if (monthIdx > 0) {
            r.chips.add('Follow-up: ' + MONTHS[monthIdx - 1].left(3) + ' ' + r.taskDueDate.year());
            r.fieldCount++;
        }
        return r;
    }

    private static void addChip(Result r, String label, String value) {
        if (String.isNotBlank(value)) {
            r.chips.add(label + ': ' + value);
            r.fieldCount++;
        }
    }

    /** First Monday of the next occurrence of the month (this year, or next year if already past). */
    @TestVisible
    private static Date firstMondayOf(Integer month, Date today) {
        Integer year = today.year();
        Date d = mondayOnOrAfter(Date.newInstance(year, month, 1));
        if (d < today) {
            d = mondayOnOrAfter(Date.newInstance(year + 1, month, 1));
        }
        return d;
    }

    private static Date mondayOnOrAfter(Date d) {
        while (dayIndex(d) != 0) {
            d = d.addDays(1);
        }
        return d;
    }

    /** 0 = Monday ... 6 = Sunday, locale independent (1 Jan 1900 was a Monday). */
    private static Integer dayIndex(Date d) {
        return Math.mod(Date.newInstance(1900, 1, 1).daysBetween(d), 7);
    }

    private static String label(Date d) {
        return DAY_NAMES[dayIndex(d)] + ' ' + d.day() + ' ' + MONTHS[d.month() - 1].left(3) + ' ' + d.year();
    }
}
