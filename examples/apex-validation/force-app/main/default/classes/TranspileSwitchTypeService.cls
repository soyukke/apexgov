public with sharing class TranspileSwitchTypeService {
    public static String classifyRecord(SObject record) {
        String kind = 'unknown';
        switch on record {
            when Account acc {
                kind = 'account:' + acc.Id;
            }
            when Contact con {
                kind = 'contact:' + con.Id;
            }
            when else {
                kind = 'other';
            }
        }
        return kind;
    }
}
