public with sharing class TranspileQueryBindsService {
    public static Integer countByName(String accountName) {
        Map<String, Object> binds = new Map<String, Object>{
            'name' => accountName
        };
        return Database.countQueryWithBinds(
            [SELECT Id FROM Account WHERE Name = :name],
            binds
        );
    }

    public static Database.QueryLocator locatorByNames(Set<String> names) {
        Map<String, Object> binds = new Map<String, Object>{
            'names' => names
        };
        return Database.getQueryLocatorWithBinds(
            [SELECT Id, Name FROM Account WHERE Name IN :names ORDER BY Name],
            binds
        );
    }
}
