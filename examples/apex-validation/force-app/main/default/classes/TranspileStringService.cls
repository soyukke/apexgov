public with sharing class TranspileStringService {
    public static String normalizeName(String rawName, List<String> tags) {
        if (String.isBlank(rawName)) {
            return 'unknown';
        }

        String safeName = String.escapeSingleQuotes(rawName);
        String joinedTags = String.join(tags, ',');
        if (String.isNotBlank(joinedTags)) {
            return String.join(new List<String>{ safeName, joinedTags }, ',');
        }
        return safeName;
    }
}
