/**
 * @description       : Backs the recordClone LWC. All of the copy logic lives in RecordCloneService.
 * @author            : Brian Ezell (Simply EZ)
 * @group             :
 * @last modified on  : 09-25-2026
 * @last modified by  : Brian Ezell (Simply EZ)
**/
public with sharing class RecordCloneController {

    /**
     * getClonePlan()
     * Returns a serialized RecordCloneService.ClonePlan: the records that will be copied
     * and the lookups that will stay linked to the original records.
     * @param linkedObjects Comma separated object API names to link instead of copy
     * @param maxDepth Levels of lookups to copy (null or negative for no limit)
     */
    @AuraEnabled
    public static String getClonePlan(Id recordId, String linkedObjects, Integer maxDepth) {
        try {
            System.debug('***STARTING RecordCloneController.getClonePlan***');
            return JSON.serialize(RecordCloneService.getClonePlan(recordId, buildOptions(linkedObjects, maxDepth)));
        } catch (Exception e) {
            throw buildAuraException(e);
        }
    }

    /**
     * cloneRecord()
     * Copies the record and returns a serialized RecordCloneService.CloneResult.
     * @param newRecordNames Serialized map of the new record's name, e.g. { "Name": "Acme (Copy)" }
     *   or { "FirstName": "Sam", "LastName": "Smith" } - see ClonePlan.nameFields
     * @param childRelationships Related records to copy too, e.g. [ "Contact.AccountId" ] - see ClonePlan.childRelationships
     */
    @AuraEnabled
    public static String cloneRecord(Id recordId, String linkedObjects, Integer maxDepth, String newRecordNames, List<String> childRelationships) {
        try {
            System.debug('***STARTING RecordCloneController.cloneRecord***');
            RecordCloneService.CloneOptions options = buildOptions(linkedObjects, maxDepth);
            if (String.isNotBlank(newRecordNames)) {
                options.newRecordNames = (Map<String, String>) JSON.deserialize(newRecordNames, Map<String, String>.class);
            }
            if (childRelationships != null) {
                options.childRelationships = new Set<String>(childRelationships);
            }
            return JSON.serialize(RecordCloneService.cloneRecord(recordId, options));
        } catch (Exception e) {
            throw buildAuraException(e);
        }
    }

    @TestVisible
    private static RecordCloneService.CloneOptions buildOptions(String linkedObjects, Integer maxDepth) {
        RecordCloneService.CloneOptions options = new RecordCloneService.CloneOptions();
        options.maxDepth = maxDepth;
        if (String.isNotBlank(linkedObjects)) {
            for (String objectName : linkedObjects.split(',')) {
                if (String.isNotBlank(objectName)) {
                    options.linkedObjects.add(objectName.trim());
                }
            }
        }
        return options;
    }

    private static AuraHandledException buildAuraException(Exception e) {
        System.debug('***EXCEPTION***');
        System.debug(e.getMessage());
        System.debug(e.getStackTraceString());
        AuraHandledException auraException = new AuraHandledException(e.getMessage());
        //setMessage so the real message is visible to tests and not just "Script-thrown exception"
        auraException.setMessage(e.getMessage());
        return auraException;
    }
}