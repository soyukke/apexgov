public with sharing class TranspileSwitchService {
    public static String normalizeStage(String stageName) {
        String normalized = 'other';
        switch on stageName {
            when 'Prospecting', 'Qualification' {
                normalized = 'open';
            }
            when 'Closed Won' {
                normalized = 'won';
            }
            when else {
                normalized = 'other';
            }
        }
        return normalized;
    }
}
