public with sharing class TranspileDoWhileService {
    public static Integer countTypedRows(List<SObject> records) {
        if (records.isEmpty()) {
            return 0;
        }

        Integer i = 0;
        Integer matched = 0;
        do {
            if (records[i] instanceof Account) {
                matched += 1;
            }
            i += 1;
        } while (i < records.size());

        return matched;
    }
}
