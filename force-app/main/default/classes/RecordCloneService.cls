/**
 * RecordCloneService
 *
 * Makes an exact copy of any record, including copies of the records it looks up to.
 *
 * For every lookup on a record being copied:
 *  - Master-detail, where the record is the detail: the copy links to the original master.
 *  - Lookup to a User or Group (queue): the copy links to the original User / Group.
 *  - Lookup to an object that can't be copied (not createable, setup objects) or that is
 *    listed in linkedObjects: the copy links to the original record.
 *  - Any other lookup: the looked-up record is copied too (with the same rules, recursively)
 *    and the copy links to that new copy.
 * A record reached by more than one path is copied once, and circular lookups are handled
 * by inserting first and filling in the lookup afterwards.
 *
 * Related records (children) can be copied too: ClonePlan.childRelationships lists the
 * relationships that can be copied (e.g. Contact.AccountId) with how many records each has,
 * and CloneOptions.childRelationships picks which ones to copy. Each child copy points at the
 * new record, and its other lookups follow the rules above.
 *
 * Unique fields are left blank on the copies, since the same value can't exist twice.
 * Queries and inserts run in USER_MODE, so the user needs create access on every object
 * copied and only fields they can read and create are copied. Everything runs under one
 * savepoint, so any failure rolls the whole copy back.
 *
 * Usage (see RecordCloneController):
 *
 *     RecordCloneService.CloneOptions options = new RecordCloneService.CloneOptions();
 *     options.linkedObjects = new Set<String>{ 'Pricebook2' };
 *     options.maxDepth = null; //no limit
 *
 *     RecordCloneService.ClonePlan plan = RecordCloneService.getClonePlan(recordId, options);
 *     RecordCloneService.CloneResult result = RecordCloneService.cloneRecord(recordId, options);
 */
public with sharing class RecordCloneService {

    //Lookups to these objects always stay pointed at the original record.
    //UserRole is here because inserting it with other records is a mixed DML error.
    private static final Set<String> ALWAYS_LINKED_OBJECTS = new Set<String>{ 'user', 'group', 'userrole' };

    //Safety net so a long chain of lookups can't run into governor limits part way through
    @TestVisible
    private static Integer maxRecords = 500;

    //Queries kept in reserve for the insert phase
    private static final Integer QUERY_HEADROOM = 5;

    //Child objects never offered as related records to copy. Files, feeds and junctions that
    //Salesforce creates itself (AccountContactRelation) either can't be copied this way or
    //would be duplicated. Share, History, Feed and ChangeEvent objects are skipped by suffix.
    private static final Set<String> EXCLUDED_CHILD_OBJECTS = new Set<String>{
        'accountcontactrelation', 'attachedcontentdocument', 'attachment', 'collaborationgrouprecord',
        'combinedattachment', 'contentdistribution', 'contentdocumentlink', 'contentversion',
        'emailmessage', 'entitysubscription', 'feedcomment', 'feeditem', 'group', 'groupmember',
        'note', 'processinstance', 'topicassignment', 'user', 'userrole'
    };
    private static final List<String> EXCLUDED_CHILD_SUFFIXES = new List<String>{ 'share', 'history', 'feed', 'changeevent' };

    //Relationship subqueries allowed in one query
    private static final Integer SUBQUERIES_PER_QUERY = 20;

    public static final String REASON_MASTER = 'Master record';
    public static final String REASON_USER_GROUP = 'User, queue or group';
    public static final String REASON_CONFIGURED = 'Set to link instead of copy';
    public static final String REASON_NOT_COPYABLE = 'This type of record can\'t be copied';
    public static final String REASON_DEPTH = 'Beyond the copy depth limit';
    public static final String REASON_NO_ACCESS = 'Not visible to you';

    //Describe results cached per object
    private static Map<Schema.SObjectType, ObjectInfo> objectInfos = new Map<Schema.SObjectType, ObjectInfo>();
    //Object.Field -> whether it's a standard detail relationship
    private static Map<String, Boolean> masterDetailByField = new Map<String, Boolean>();

    //Start - public API

    /**
     * getClonePlan()
     * Work out which records will be copied and which lookups will stay linked
     * to the original records, without changing anything.
     */
    public static ClonePlan getClonePlan(Id recordId, CloneOptions options) {
        CloneGraph graph = buildGraph(recordId, options);
        ClonePlan plan = graph.toPlan();
        plan.childRelationships = countChildRelationships(graph.root.info, recordId);
        return plan;
    }

    /**
     * cloneRecord()
     * Copy the record and every record it looks up to that should be copied.
     * @return The new copy of recordId and a map of every original Id -> copy Id
     */
    public static CloneResult cloneRecord(Id recordId, CloneOptions options) {
        CloneGraph graph = buildGraph(recordId, options);
        Map<String, String> newRecordNames = validateNewRecordNames(graph.root.info, options == null ? null : options.newRecordNames);

        Savepoint savepoint = Database.setSavepoint();
        try {
            insertCopies(graph, newRecordNames);

            CloneResult result = new CloneResult();
            result.newRecordId = graph.root.copy.Id;
            result.copiedCount = graph.nodes.size();
            for (CloneNode node : graph.nodes) {
                result.copiedRecordIds.put(node.sourceId, node.copy.Id);
            }
            return result;
        } catch (Exception e) {
            Database.rollback(savepoint);
            System.debug('RecordCloneService.cloneRecord failed: ' + e.getMessage());
            System.debug(e.getStackTraceString());
            throw e;
        }
    }

    /**
     * validateNewRecordNames()
     * The name typed in for the new record. Only the fields returned in
     * ClonePlan.nameFields can be set, and required ones can't be blank.
     * @return Field API name -> value, empty when the object has no name the user can set
     */
    private static Map<String, String> validateNewRecordNames(ObjectInfo info, Map<String, String> newRecordNames) {
        Map<String, String> valuesByLowerName = new Map<String, String>();
        if (newRecordNames != null) {
            for (String fieldName : newRecordNames.keySet()) {
                valuesByLowerName.put(fieldName.toLowerCase(), newRecordNames.get(fieldName));
            }
        }

        Set<String> allowedFields = new Set<String>();
        Map<String, String> validated = new Map<String, String>();
        for (Schema.DescribeFieldResult fieldDescribe : info.nameInputFields) {
            String fieldName = fieldDescribe.getName();
            allowedFields.add(fieldName.toLowerCase());
            String value = valuesByLowerName.get(fieldName.toLowerCase());
            value = value == null ? null : value.trim();
            if (String.isBlank(value) && isRequiredName(fieldDescribe)) {
                throw new RecordCloneException('Enter a ' + fieldDescribe.getLabel() + ' for the new record.');
            }
            validated.put(fieldName, String.isBlank(value) ? null : value);
        }
        for (String fieldName : valuesByLowerName.keySet()) {
            if (!allowedFields.contains(fieldName)) {
                throw new RecordCloneException('The field ' + fieldName + ' can\'t be set when copying a ' + info.label + '.');
            }
        }
        return validated;
    }

    private static Boolean isRequiredName(Schema.DescribeFieldResult fieldDescribe) {
        return !fieldDescribe.isNillable() || fieldDescribe.isNameField();
    }

    //End - public API

    //Start - build the graph of records to copy

    /**
     * buildGraph()
     * Walk the lookups one level at a time, starting at recordId. Each level runs
     * one query per object, so the number of queries depends on how deep the
     * lookups go rather than on how many records there are.
     */
    private static CloneGraph buildGraph(Id recordId, CloneOptions options) {
        if (recordId == null) {
            throw new RecordCloneException('A record is required to copy.');
        }
        options = options == null ? new CloneOptions() : options;
        Set<String> linkedObjects = new Set<String>();
        if (options.linkedObjects != null) {
            for (String objectName : options.linkedObjects) {
                if (String.isNotBlank(objectName)) {
                    linkedObjects.add(objectName.trim().toLowerCase());
                }
            }
        }

        ObjectInfo rootInfo = getObjectInfo(recordId.getSObjectType());
        if (!rootInfo.isCopyable) {
            throw new RecordCloneException('You don\'t have access to create ' + rootInfo.labelPlural + '.');
        }

        CloneGraph graph = new CloneGraph();
        graph.root = new CloneNode(recordId, rootInfo, 0, rootInfo.label);
        graph.nodesBySourceId.put(recordId, graph.root);

        List<CloneNode> level = new List<CloneNode>{ graph.root };
        Boolean childrenAdded = false;
        while (!level.isEmpty()) {
            querySources(level);

            List<CloneNode> nextLevel = new List<CloneNode>();
            for (CloneNode node : level) {
                if (node.source == null) {
                    continue;
                }
                graph.nodes.add(node);
                for (Schema.DescribeFieldResult fieldDescribe : node.info.referenceFields) {
                    CloneNode target = planLookup(graph, node, fieldDescribe, linkedObjects, options.maxDepth);
                    if (target != null) {
                        nextLevel.add(target);
                    }
                }
            }
            if (graph.root.source == null) {
                throw new RecordCloneException('The record could not be found, or you do not have access to it.');
            }
            //The selected related records join the level after the record itself
            if (!childrenAdded) {
                nextLevel.addAll(addChildNodes(graph, options.childRelationships));
                childrenAdded = true;
            }
            if (graph.nodesBySourceId.size() > maxRecords) {
                throw new RecordCloneException('More than ' + maxRecords + ' records would need to be copied. ' +
                    'Copy fewer related records, set a copy depth limit or link more objects instead of copying them.');
            }
            level = nextLevel;
        }

        //Lookups to records the user can't see stay linked to the original record
        for (CloneNode node : graph.nodes) {
            for (String fieldName : new List<String>(node.copiedLookups.keySet())) {
                CloneNode target = graph.nodesBySourceId.get(node.copiedLookups.get(fieldName));
                if (target.source == null) {
                    node.copiedLookups.remove(fieldName);
                    graph.addLinked(node, node.info.fieldsByName.get(fieldName), target.sourceId, REASON_NO_ACCESS);
                }
            }
        }
        return graph;
    }

    /**
     * planLookup()
     * Decide whether a lookup's record is copied or linked.
     * @return A new node when the looked-up record still has to be queried, otherwise null
     */
    private static CloneNode planLookup(CloneGraph graph, CloneNode node, Schema.DescribeFieldResult fieldDescribe,
            Set<String> linkedObjects, Integer maxDepth) {

        Object value = node.source.get(fieldDescribe.getName());
        //Already decided - a related record's lookup to the record being copied
        if (value == null || node.copiedLookups.containsKey(fieldDescribe.getName())) {
            return null;
        }
        Id targetId = (Id) value;
        ObjectInfo targetInfo = getObjectInfo(targetId.getSObjectType());

        String reason = getLinkReason(fieldDescribe, targetInfo, linkedObjects);
        if (reason == null && maxDepth != null && maxDepth >= 0 && node.depth >= maxDepth && !graph.nodesBySourceId.containsKey(targetId)) {
            reason = REASON_DEPTH;
        }
        if (reason != null) {
            graph.addLinked(node, fieldDescribe, targetId, reason);
            return null;
        }

        node.copiedLookups.put(fieldDescribe.getName(), targetId);
        if (graph.nodesBySourceId.containsKey(targetId)) {
            return null;
        }
        CloneNode target = new CloneNode(targetId, targetInfo, node.depth + 1, node.path + ' › ' + fieldDescribe.getLabel());
        graph.nodesBySourceId.put(targetId, target);
        return target;
    }

    /**
     * getLinkReason()
     * Why the lookup's record is linked instead of copied, or null when it should be copied.
     */
    @TestVisible
    private static String getLinkReason(Schema.DescribeFieldResult fieldDescribe, ObjectInfo targetInfo, Set<String> linkedObjects) {
        if (isMasterDetail(fieldDescribe)) {
            return REASON_MASTER;
        }
        String targetName = targetInfo.apiName.toLowerCase();
        if (targetName == 'user' || targetName == 'group') {
            return REASON_USER_GROUP;
        }
        if (linkedObjects.contains(targetName)) {
            return REASON_CONFIGURED;
        }
        if (ALWAYS_LINKED_OBJECTS.contains(targetName) || !targetInfo.isCopyable) {
            return REASON_NOT_COPYABLE;
        }
        return null;
    }

    /**
     * isMasterDetail()
     * Custom master-detail fields have a relationship order. Standard detail objects
     * (e.g. OpportunityLineItem.OpportunityId) are required lookups whose parent's
     * child relationship cascade deletes - the field describe itself doesn't say so.
     */
    @TestVisible
    private static Boolean isMasterDetail(Schema.DescribeFieldResult fieldDescribe) {
        if (fieldDescribe.getRelationshipOrder() != null) {
            return true;
        }
        if (fieldDescribe.isNillable() || fieldDescribe.getReferenceTo().size() != 1) {
            return false;
        }
        String key = String.valueOf(fieldDescribe.getSObjectType()) + '.' + fieldDescribe.getName();
        if (!masterDetailByField.containsKey(key)) {
            Boolean isCascadeDelete = false;
            Schema.SObjectField field = fieldDescribe.getSObjectField();
            for (Schema.ChildRelationship relationship : fieldDescribe.getReferenceTo()[0].getDescribe().getChildRelationships()) {
                if (relationship.getField() == field && relationship.getChildSObject() == fieldDescribe.getSObjectType()) {
                    isCascadeDelete = relationship.isCascadeDelete();
                    break;
                }
            }
            masterDetailByField.put(key, isCascadeDelete);
        }
        return masterDetailByField.get(key);
    }

    /**
     * querySources()
     * Query every copyable field of the nodes in one level, one query per object.
     * Nodes whose record isn't visible to the user are left with a null source.
     */
    private static void querySources(List<CloneNode> nodes) {
        Map<Schema.SObjectType, Set<Id>> idsByType = new Map<Schema.SObjectType, Set<Id>>();
        for (CloneNode node : nodes) {
            if (!idsByType.containsKey(node.info.sObjectType)) {
                idsByType.put(node.info.sObjectType, new Set<Id>());
            }
            idsByType.get(node.info.sObjectType).add(node.sourceId);
        }

        Map<Id, SObject> sources = new Map<Id, SObject>();
        for (Schema.SObjectType sObjectType : idsByType.keySet()) {
            checkQueryHeadroom();
            Set<Id> recordIds = idsByType.get(sObjectType);
            String query = 'SELECT ' + String.join(new List<String>(getObjectInfo(sObjectType).selectFields), ', ') +
                ' FROM ' + getObjectInfo(sObjectType).apiName + ' WHERE Id IN :recordIds';
            System.debug('RecordCloneService query = ' + query);
            sources.putAll(Database.queryWithBinds(query, new Map<String, Object>{ 'recordIds' => recordIds }, AccessLevel.USER_MODE));
        }

        for (CloneNode node : nodes) {
            node.source = sources.get(node.sourceId);
        }
    }

    /**
     * addChildNodes()
     * Add the related records of the selected child relationships. Their lookup to the
     * record being copied always points at the new copy - even for master-detail.
     * @param relationshipKeys ChildObject.Field keys from ClonePlan.childRelationships
     * @return The new nodes, still to be queried
     */
    private static List<CloneNode> addChildNodes(CloneGraph graph, Set<String> relationshipKeys) {
        List<CloneNode> childNodes = new List<CloneNode>();
        if (relationshipKeys == null || relationshipKeys.isEmpty()) {
            return childNodes;
        }

        Map<String, ChildRelationshipInfo> relationshipsByKey = new Map<String, ChildRelationshipInfo>();
        for (ChildRelationshipInfo relationship : getChildRelationshipInfos(graph.root.info)) {
            relationshipsByKey.put(relationship.key.toLowerCase(), relationship);
        }

        Id rootId = graph.root.sourceId;
        for (String key : relationshipKeys) {
            ChildRelationshipInfo relationship = relationshipsByKey.get(key.trim().toLowerCase());
            if (relationship == null) {
                throw new RecordCloneException('The related records ' + key + ' can\'t be copied with a ' + graph.root.info.label + '.');
            }
            ObjectInfo childInfo = getObjectInfo(relationship.childType);
            if (!childInfo.fieldsByName.containsKey(relationship.fieldApiName)) {
                throw new RecordCloneException('You don\'t have access to set ' + relationship.fieldLabel + ' on ' + relationship.childObjectLabel + '.');
            }
            checkQueryHeadroom();

            String query = 'SELECT Id FROM ' + childInfo.apiName + ' WHERE ' + relationship.fieldApiName + ' = :rootId';
            for (SObject child : Database.queryWithBinds(query, new Map<String, Object>{ 'rootId' => rootId }, AccessLevel.USER_MODE)) {
                CloneNode childNode = graph.nodesBySourceId.get(child.Id);
                if (childNode == null) {
                    childNode = new CloneNode(child.Id, childInfo, 1, graph.root.info.label + ' › ' + relationship.childObjectLabel);
                    graph.nodesBySourceId.put(child.Id, childNode);
                    childNodes.add(childNode);
                }
                childNode.copiedLookups.put(relationship.fieldApiName, rootId);
            }
        }
        return childNodes;
    }

    /**
     * getChildRelationshipInfos()
     * Child relationships whose records the user can copy: the child object must be
     * createable and queryable, and its lookup to this object createable.
     */
    private static List<ChildRelationshipInfo> getChildRelationshipInfos(ObjectInfo parentInfo) {
        List<ChildRelationshipInfo> relationships = new List<ChildRelationshipInfo>();
        Set<String> seenKeys = new Set<String>();

        for (Schema.ChildRelationship relationship : parentInfo.sObjectType.getDescribe().getChildRelationships()) {
            if (String.isBlank(relationship.getRelationshipName())) {
                continue;
            }
            Schema.DescribeSObjectResult childDescribe = relationship.getChildSObject().getDescribe(SObjectDescribeOptions.DEFERRED);
            if (isExcludedChildObject(childDescribe.getName()) || !childDescribe.isCreateable() ||
                    !childDescribe.isQueryable() || !childDescribe.isAccessible()) {
                continue;
            }
            Schema.DescribeFieldResult fieldDescribe = relationship.getField().getDescribe();
            String key = childDescribe.getName() + '.' + fieldDescribe.getName();
            if (!fieldDescribe.isCreateable() || !fieldDescribe.isAccessible() || !fieldDescribe.isFilterable() || seenKeys.contains(key)) {
                continue;
            }
            seenKeys.add(key);

            ChildRelationshipInfo info = new ChildRelationshipInfo();
            info.key = key;
            info.childType = relationship.getChildSObject();
            info.childObjectApiName = childDescribe.getName();
            info.childObjectLabel = childDescribe.getLabelPlural();
            info.fieldApiName = fieldDescribe.getName();
            info.fieldLabel = fieldDescribe.getLabel();
            info.relationshipName = relationship.getRelationshipName();
            relationships.add(info);
        }
        return relationships;
    }

    private static Boolean isExcludedChildObject(String objectName) {
        String lowerName = objectName.toLowerCase();
        if (EXCLUDED_CHILD_OBJECTS.contains(lowerName)) {
            return true;
        }
        for (String suffix : EXCLUDED_CHILD_SUFFIXES) {
            if (lowerName.endsWith(suffix)) {
                return true;
            }
        }
        return false;
    }

    /**
     * countChildRelationships()
     * Count the related records of every child relationship that can be copied,
     * using relationship subqueries (20 per query). Only relationships with
     * records are returned, sorted by label.
     */
    private static List<ChildRelationshipSummary> countChildRelationships(ObjectInfo parentInfo, Id recordId) {
        List<ChildRelationshipInfo> relationships = getChildRelationshipInfos(parentInfo);
        Map<String, ChildRelationshipSummary> summariesBySortKey = new Map<String, ChildRelationshipSummary>();

        for (Integer start = 0; start < relationships.size(); start += SUBQUERIES_PER_QUERY) {
            List<ChildRelationshipInfo> chunk = new List<ChildRelationshipInfo>();
            for (Integer i = start; i < Math.min(start + SUBQUERIES_PER_QUERY, relationships.size()); i++) {
                chunk.add(relationships[i]);
            }
            Map<String, Integer> counts = countChunk(parentInfo, recordId, chunk);
            for (ChildRelationshipInfo relationship : chunk) {
                Integer count = counts.get(relationship.key);
                if (count == null || count == 0) {
                    continue;
                }
                ChildRelationshipSummary summary = new ChildRelationshipSummary();
                summary.key = relationship.key;
                summary.childObjectApiName = relationship.childObjectApiName;
                summary.childObjectLabel = relationship.childObjectLabel;
                summary.fieldApiName = relationship.fieldApiName;
                summary.fieldLabel = relationship.fieldLabel;
                summary.count = count;
                summariesBySortKey.put(relationship.childObjectLabel.toLowerCase() + '|' + relationship.key, summary);
            }
        }

        List<String> sortKeys = new List<String>(summariesBySortKey.keySet());
        sortKeys.sort();
        List<ChildRelationshipSummary> summaries = new List<ChildRelationshipSummary>();
        for (String sortKey : sortKeys) {
            summaries.add(summariesBySortKey.get(sortKey));
        }
        return summaries;
    }

    /**
     * countChunk()
     * One query with a subquery per relationship. Some relationships can't be used in a
     * subquery, so when the combined query fails each one is counted on its own instead.
     * @return Relationship key -> number of related records (missing when it couldn't be counted)
     */
    private static Map<String, Integer> countChunk(ObjectInfo parentInfo, Id recordId, List<ChildRelationshipInfo> chunk) {
        Map<String, Integer> counts = new Map<String, Integer>();
        List<String> subqueries = new List<String>();
        for (ChildRelationshipInfo relationship : chunk) {
            subqueries.add('(SELECT Id FROM ' + relationship.relationshipName + ')');
        }

        try {
            checkQueryHeadroom();
            String query = 'SELECT Id, ' + String.join(subqueries, ', ') + ' FROM ' + parentInfo.apiName + ' WHERE Id = :recordId';
            List<SObject> parents = Database.queryWithBinds(query, new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
            if (parents.isEmpty()) {
                return counts;
            }
            for (ChildRelationshipInfo relationship : chunk) {
                List<SObject> children = parents[0].getSObjects(relationship.relationshipName);
                counts.put(relationship.key, children == null ? 0 : children.size());
            }
            return counts;
        } catch (QueryException e) {
            System.debug('RecordCloneService child count subqueries failed, counting one at a time: ' + e.getMessage());
        }

        for (ChildRelationshipInfo relationship : chunk) {
            if (Limits.getQueries() >= Limits.getLimitQueries() - QUERY_HEADROOM) {
                break;
            }
            try {
                String query = 'SELECT COUNT() FROM ' + relationship.childObjectApiName + ' WHERE ' + relationship.fieldApiName + ' = :recordId';
                counts.put(relationship.key, Database.countQueryWithBinds(query, new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE));
            } catch (Exception e) {
                System.debug('RecordCloneService could not count ' + relationship.key + ': ' + e.getMessage());
            }
        }
        return counts;
    }

    private static void checkQueryHeadroom() {
        if (Limits.getQueries() >= Limits.getLimitQueries() - QUERY_HEADROOM) {
            throw new RecordCloneException('This record looks up through too many levels of records to copy in one go. ' +
                'Set a copy depth limit or link more objects instead of copying them.');
        }
    }

    private class ChildRelationshipInfo {
        public String key;
        public Schema.SObjectType childType;
        public String childObjectApiName;
        public String childObjectLabel;
        public String fieldApiName;
        public String fieldLabel;
        public String relationshipName;
    }

    //End - build the graph of records to copy

    //Start - insert the copies

    /**
     * insertCopies()
     * The new record gets the name typed in by the user (newRecordNames).
     * Insert the copies so every record is inserted after the records it looks up to.
     * Each round inserts every record that is ready, one DML per object. When only
     * circular lookups are left, one nillable lookup is left blank at insert and
     * filled in by an update at the end.
     */
    private static void insertCopies(CloneGraph graph, Map<String, String> newRecordNames) {
        for (CloneNode node : graph.nodes) {
            node.copy = buildCopy(node);
        }
        for (String fieldName : newRecordNames.keySet()) {
            graph.root.copy.put(fieldName, newRecordNames.get(fieldName));
        }

        List<CloneNode> remaining = new List<CloneNode>(graph.nodes);
        while (!remaining.isEmpty()) {
            List<CloneNode> ready = new List<CloneNode>();
            List<CloneNode> waiting = new List<CloneNode>();
            for (CloneNode node : remaining) {
                if (isReadyToInsert(graph, node)) {
                    ready.add(node);
                } else {
                    waiting.add(node);
                }
            }

            if (ready.isEmpty()) {
                deferOneLookup(graph, waiting);
                continue;
            }

            for (CloneNode node : ready) {
                for (String fieldName : node.copiedLookups.keySet()) {
                    if (!node.deferredLookups.contains(fieldName)) {
                        node.copy.put(fieldName, graph.nodesBySourceId.get(node.copiedLookups.get(fieldName)).copy.Id);
                    }
                }
            }
            insertByType(ready);
            remaining = waiting;
        }

        List<CloneNode> deferredNodes = new List<CloneNode>();
        for (CloneNode node : graph.nodes) {
            if (!node.deferredLookups.isEmpty()) {
                deferredNodes.add(node);
            }
        }
        updateDeferredLookups(graph, deferredNodes);
    }

    /**
     * buildCopy()
     * A new record with every copyable field of the source. Lookups that will point
     * at a copy are left blank until the copy exists, and unique fields are left blank.
     */
    private static SObject buildCopy(CloneNode node) {
        SObject copy = node.info.sObjectType.newSObject();
        for (Schema.DescribeFieldResult fieldDescribe : node.info.copyFields) {
            String fieldName = fieldDescribe.getName();
            if (fieldDescribe.isUnique() || node.copiedLookups.containsKey(fieldName)) {
                continue;
            }
            Object value = node.source.get(fieldName);
            if (value != null) {
                copy.put(fieldName, value);
            }
        }
        return copy;
    }

    private static Boolean isReadyToInsert(CloneGraph graph, CloneNode node) {
        for (String fieldName : node.copiedLookups.keySet()) {
            if (!node.deferredLookups.contains(fieldName) &&
                    graph.nodesBySourceId.get(node.copiedLookups.get(fieldName)).copy.Id == null) {
                return false;
            }
        }
        return true;
    }

    /**
     * deferOneLookup()
     * Every remaining record is waiting on another remaining record, so there is a
     * circle of lookups. Break it by leaving one nillable lookup blank at insert.
     */
    private static void deferOneLookup(CloneGraph graph, List<CloneNode> waiting) {
        for (CloneNode node : waiting) {
            for (String fieldName : node.copiedLookups.keySet()) {
                Boolean isPending = graph.nodesBySourceId.get(node.copiedLookups.get(fieldName)).copy.Id == null;
                if (isPending && !node.deferredLookups.contains(fieldName) && node.info.fieldsByName.get(fieldName).isNillable()) {
                    node.deferredLookups.add(fieldName);
                    return;
                }
            }
        }
        throw new RecordCloneException('These records look up to each other through required fields, so they can\'t be copied.');
    }

    private static void insertByType(List<CloneNode> nodes) {
        Database.DMLOptions dmlOptions = new Database.DMLOptions();
        dmlOptions.OptAllOrNone = true;
        //An exact copy is a duplicate by definition, so don't let alert-only duplicate rules block it
        dmlOptions.DuplicateRuleHeader.AllowSave = true;

        for (List<CloneNode> typeNodes : groupByType(nodes).values()) {
            List<SObject> copies = new List<SObject>();
            for (CloneNode node : typeNodes) {
                copies.add(node.copy);
            }
            try {
                Database.insert(copies, dmlOptions, AccessLevel.USER_MODE);
            } catch (DmlException e) {
                CloneNode failed = typeNodes[e.getDmlIndex(0)];
                throw new RecordCloneException('Could not copy ' + failed.info.label + ' "' + failed.getName() + '": ' + e.getDmlMessage(0));
            }
        }
    }

    private static void updateDeferredLookups(CloneGraph graph, List<CloneNode> nodes) {
        for (List<CloneNode> typeNodes : groupByType(nodes).values()) {
            List<SObject> updates = new List<SObject>();
            for (CloneNode node : typeNodes) {
                SObject copyUpdate = node.info.sObjectType.newSObject(node.copy.Id);
                for (String fieldName : node.deferredLookups) {
                    copyUpdate.put(fieldName, graph.nodesBySourceId.get(node.copiedLookups.get(fieldName)).copy.Id);
                }
                updates.add(copyUpdate);
            }
            Database.update(updates, AccessLevel.USER_MODE);
        }
    }

    private static Map<Schema.SObjectType, List<CloneNode>> groupByType(List<CloneNode> nodes) {
        Map<Schema.SObjectType, List<CloneNode>> nodesByType = new Map<Schema.SObjectType, List<CloneNode>>();
        for (CloneNode node : nodes) {
            if (!nodesByType.containsKey(node.info.sObjectType)) {
                nodesByType.put(node.info.sObjectType, new List<CloneNode>());
            }
            nodesByType.get(node.info.sObjectType).add(node);
        }
        return nodesByType;
    }

    //End - insert the copies

    //Start - describe helpers

    private static ObjectInfo getObjectInfo(Schema.SObjectType sObjectType) {
        if (!objectInfos.containsKey(sObjectType)) {
            objectInfos.put(sObjectType, new ObjectInfo(sObjectType));
        }
        return objectInfos.get(sObjectType);
    }

    /**
     * ObjectInfo
     * The fields of an object that can be copied (readable and createable), its
     * lookups, its name field, and the relationship paths used to show lookup names.
     */
    @TestVisible
    private class ObjectInfo {
        public Schema.SObjectType sObjectType;
        public String apiName;
        public String label;
        public String labelPlural;
        public Boolean isCopyable;
        public String nameField;
        //Fields the user types the new record's name into: the name field when it can be
        //set, otherwise First and Last Name (Contact, Lead). Empty for auto-numbers.
        public List<Schema.DescribeFieldResult> nameInputFields = new List<Schema.DescribeFieldResult>();
        public List<Schema.DescribeFieldResult> copyFields = new List<Schema.DescribeFieldResult>();
        public List<Schema.DescribeFieldResult> referenceFields = new List<Schema.DescribeFieldResult>();
        public Map<String, Schema.DescribeFieldResult> fieldsByName = new Map<String, Schema.DescribeFieldResult>();
        public Set<String> selectFields = new Set<String>{ 'Id' };

        public ObjectInfo(Schema.SObjectType sObjectType) {
            Schema.DescribeSObjectResult objectDescribe = sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED);
            this.sObjectType = sObjectType;
            apiName = objectDescribe.getName();
            label = objectDescribe.getLabel();
            labelPlural = objectDescribe.getLabelPlural();
            isCopyable = objectDescribe.isCreateable() && objectDescribe.isQueryable() && objectDescribe.isAccessible();
            if (!isCopyable) {
                return;
            }

            for (Schema.SObjectField field : objectDescribe.fields.getMap().values()) {
                Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
                if (!fieldDescribe.isAccessible()) {
                    continue;
                }
                if (fieldDescribe.isNameField() && nameField == null) {
                    nameField = fieldDescribe.getName();
                    selectFields.add(nameField);
                }
                if (!fieldDescribe.isCreateable() || isExcludedType(fieldDescribe.getType())) {
                    continue;
                }
                copyFields.add(fieldDescribe);
                fieldsByName.put(fieldDescribe.getName(), fieldDescribe);
                selectFields.add(fieldDescribe.getName());
                if (fieldDescribe.getType() == Schema.DisplayType.REFERENCE) {
                    referenceFields.add(fieldDescribe);
                    String namePath = lookupNamePath(fieldDescribe);
                    if (namePath != null) {
                        selectFields.add(namePath);
                    }
                }
            }

            if (nameField != null && fieldsByName.containsKey(nameField)) {
                nameInputFields.add(fieldsByName.get(nameField));
            } else if (fieldsByName.containsKey('FirstName') && fieldsByName.containsKey('LastName')) {
                nameInputFields.add(fieldsByName.get('FirstName'));
                nameInputFields.add(fieldsByName.get('LastName'));
            }
        }
    }

    //Compound Address and Geolocation fields are copied through their component fields
    private static Boolean isExcludedType(Schema.DisplayType fieldType) {
        return fieldType == Schema.DisplayType.ADDRESS ||
            fieldType == Schema.DisplayType.LOCATION;
    }

    /**
     * lookupNamePath()
     * Relationship path used to show a linked record's name (e.g. OwnerId -> Owner.Name),
     * or null when the target has no readable Name.
     */
    private static String lookupNamePath(Schema.DescribeFieldResult fieldDescribe) {
        if (String.isBlank(fieldDescribe.getRelationshipName())) {
            return null;
        }
        List<Schema.SObjectType> referenceTo = fieldDescribe.getReferenceTo();
        if (referenceTo.isEmpty()) {
            return null;
        }
        //Polymorphic lookups (Owner, What, Who) always expose Name
        if (referenceTo.size() == 1) {
            Schema.DescribeSObjectResult targetDescribe = referenceTo[0].getDescribe(SObjectDescribeOptions.DEFERRED);
            Schema.SObjectField nameField = targetDescribe.fields.getMap().get('Name');
            if (!targetDescribe.isAccessible() || nameField == null ||
                    !nameField.getDescribe().isAccessible() || !nameField.getDescribe().isNameField()) {
                return null;
            }
        }
        return fieldDescribe.getRelationshipName() + '.Name';
    }

    //End - describe helpers

    //Start - graph classes

    private class CloneGraph {
        public CloneNode root;
        //Records that will be copied, in the order they were found (root first)
        public List<CloneNode> nodes = new List<CloneNode>();
        //Every record reached, including ones that turned out not to be visible
        public Map<Id, CloneNode> nodesBySourceId = new Map<Id, CloneNode>();
        public List<LinkedReference> linkedReferences = new List<LinkedReference>();

        public void addLinked(CloneNode node, Schema.DescribeFieldResult fieldDescribe, Id targetId, String reason) {
            LinkedReference linked = new LinkedReference();
            linked.fromRecordId = node.sourceId;
            linked.fromRecordName = node.getName();
            linked.fromObjectLabel = node.info.label;
            linked.fieldApiName = fieldDescribe.getName();
            linked.fieldLabel = fieldDescribe.getLabel();
            linked.targetId = targetId;
            linked.targetObjectLabel = targetId.getSObjectType().getDescribe(SObjectDescribeOptions.DEFERRED).getLabel();
            linked.targetName = getLookupName(node.source, fieldDescribe, targetId);
            linked.reason = reason;
            linkedReferences.add(linked);
        }

        public ClonePlan toPlan() {
            ClonePlan plan = new ClonePlan();
            plan.recordId = root.sourceId;
            plan.objectApiName = root.info.apiName;
            plan.objectLabel = root.info.label;
            plan.recordName = root.getName();
            for (Schema.DescribeFieldResult fieldDescribe : root.info.nameInputFields) {
                NameField nameField = new NameField();
                nameField.apiName = fieldDescribe.getName();
                nameField.label = fieldDescribe.getLabel();
                nameField.currentValue = (String) root.source.get(fieldDescribe.getName());
                nameField.required = isRequiredName(fieldDescribe);
                nameField.maxLength = fieldDescribe.getLength();
                plan.nameFields.add(nameField);
            }
            for (CloneNode node : nodes) {
                PlannedRecord planned = new PlannedRecord();
                planned.sourceId = node.sourceId;
                planned.objectApiName = node.info.apiName;
                planned.objectLabel = node.info.label;
                planned.name = node.getName();
                planned.depth = node.depth;
                planned.path = node.path;
                plan.records.add(planned);
            }
            plan.linkedReferences = linkedReferences;
            return plan;
        }
    }

    private static String getLookupName(SObject source, Schema.DescribeFieldResult fieldDescribe, Id targetId) {
        if (lookupNamePath(fieldDescribe) != null) {
            SObject related = source.getSObject(fieldDescribe.getRelationshipName());
            if (related != null && related.get('Name') != null) {
                return String.valueOf(related.get('Name'));
            }
        }
        return String.valueOf(targetId);
    }

    private class CloneNode {
        public Id sourceId;
        public ObjectInfo info;
        public Integer depth;
        //How the record was reached, e.g. "Contact › Account ID › Parent Account ID"
        public String path;
        public SObject source;
        public SObject copy;
        //Lookup field -> original Id of the record whose copy it will point at
        public Map<String, Id> copiedLookups = new Map<String, Id>();
        //Lookups left blank at insert and filled in afterwards (circular lookups)
        public Set<String> deferredLookups = new Set<String>();

        public CloneNode(Id sourceId, ObjectInfo info, Integer depth, String path) {
            this.sourceId = sourceId;
            this.info = info;
            this.depth = depth;
            this.path = path;
        }

        public String getName() {
            if (source != null && info.nameField != null && source.get(info.nameField) != null) {
                return String.valueOf(source.get(info.nameField));
            }
            return String.valueOf(sourceId);
        }
    }

    //End - graph classes

    public class CloneOptions {
        //Object API names whose records are linked instead of copied
        public Set<String> linkedObjects = new Set<String>();
        //How many levels of lookups to copy. 0 copies only the record, null or negative has no limit.
        public Integer maxDepth;
        //Name for the new record: field API name (from ClonePlan.nameFields) -> value
        public Map<String, String> newRecordNames = new Map<String, String>();
        //Related records to copy too: ChildObject.Field keys from ClonePlan.childRelationships
        public Set<String> childRelationships = new Set<String>();
    }

    public class ClonePlan {
        public Id recordId;
        public String objectApiName;
        public String objectLabel;
        public String recordName;
        //Fields to ask for the new record's name. Empty when the name can't be set (e.g. auto-numbers).
        public List<NameField> nameFields = new List<NameField>();
        //Records that will be copied, root first
        public List<PlannedRecord> records = new List<PlannedRecord>();
        //Lookups that will point at the original record
        public List<LinkedReference> linkedReferences = new List<LinkedReference>();
        //Related records that can be copied too (only relationships that have records)
        public List<ChildRelationshipSummary> childRelationships = new List<ChildRelationshipSummary>();
    }

    public class ChildRelationshipSummary {
        //ChildObject.Field, e.g. Contact.AccountId - pass back in CloneOptions.childRelationships
        public String key;
        public String childObjectApiName;
        public String childObjectLabel;
        public String fieldApiName;
        public String fieldLabel;
        public Integer count;
    }

    public class NameField {
        public String apiName;
        public String label;
        public String currentValue;
        public Boolean required;
        public Integer maxLength;
    }

    public class PlannedRecord {
        public Id sourceId;
        public String objectApiName;
        public String objectLabel;
        public String name;
        public Integer depth;
        public String path;
    }

    public class LinkedReference {
        public Id fromRecordId;
        public String fromRecordName;
        public String fromObjectLabel;
        public String fieldApiName;
        public String fieldLabel;
        public Id targetId;
        public String targetName;
        public String targetObjectLabel;
        public String reason;
    }

    public class CloneResult {
        public Id newRecordId;
        public Integer copiedCount;
        public Map<Id, Id> copiedRecordIds = new Map<Id, Id>();
    }

    public class RecordCloneException extends Exception {}
}