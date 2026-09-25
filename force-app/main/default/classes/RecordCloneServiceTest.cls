/**
 * @description Unit tests for RecordCloneService and RecordCloneController.
 * Copies a Contact that looks up to an Account (which looks up to a parent Account)
 * and reports to another Contact at the same Account.
 */
@IsTest
private class RecordCloneServiceTest {

    private static final String PARENT_ACCOUNT_NAME = 'Clone Parent Holdings';
    private static final String ACCOUNT_NAME = 'Clone Branch Office';
    private static final String CONTACT_LAST_NAME = 'Clone Source';
    private static final String MANAGER_LAST_NAME = 'Clone Manager';
    private static final String COPY_LAST_NAME = 'Clone Copy';

    @TestSetup
    static void setupTestData() {
        Account parentAccount = new Account(Name = PARENT_ACCOUNT_NAME, Phone = '111-111-1111');
        insert parentAccount;
        Account account = new Account(Name = ACCOUNT_NAME, Phone = '222-222-2222', ParentId = parentAccount.Id);
        insert account;
        Contact manager = new Contact(FirstName = 'Mia', LastName = MANAGER_LAST_NAME, AccountId = account.Id);
        insert manager;
        insert new Contact(FirstName = 'Sam', LastName = CONTACT_LAST_NAME, Email = 'sam.clone@example.com',
            Title = 'Engineer', AccountId = account.Id, ReportsToId = manager.Id);
    }

    private static Contact getSourceContact() {
        return [SELECT Id, OwnerId FROM Contact WHERE LastName = :CONTACT_LAST_NAME];
    }

    private static RecordCloneService.CloneOptions options(Integer maxDepth, Set<String> linkedObjects) {
        RecordCloneService.CloneOptions options = new RecordCloneService.CloneOptions();
        options.maxDepth = maxDepth;
        options.linkedObjects = linkedObjects;
        options.newRecordNames = new Map<String, String>{ 'FirstName' => 'Sam', 'LastName' => COPY_LAST_NAME };
        return options;
    }

    @IsTest
    static void cloneRecord_CopiesRecordAndLookupsRecursively() {
        Contact source = getSourceContact();
        Account originalAccount = [SELECT Id, ParentId FROM Account WHERE Name = :ACCOUNT_NAME];
        Contact originalManager = [SELECT Id FROM Contact WHERE LastName = :MANAGER_LAST_NAME];

        Test.startTest();
        RecordCloneService.CloneResult result = RecordCloneService.cloneRecord(source.Id, options(null, null));
        Test.stopTest();

        //Contact, manager Contact, Account and parent Account. The Account is reached twice but copied once.
        Assert.areEqual(4, result.copiedCount);
        Assert.areEqual(2, [SELECT COUNT() FROM Account WHERE Name = :ACCOUNT_NAME]);
        Assert.areEqual(2, [SELECT COUNT() FROM Account WHERE Name = :PARENT_ACCOUNT_NAME]);

        Contact copy = [SELECT Id, FirstName, LastName, Email, Title, OwnerId, AccountId, ReportsToId,
                Account.Name, Account.Phone, Account.ParentId, Account.Parent.Name, ReportsTo.AccountId
            FROM Contact WHERE Id = :result.newRecordId];

        Assert.areNotEqual(source.Id, copy.Id);
        Assert.areEqual('Sam', copy.FirstName);
        Assert.areEqual(COPY_LAST_NAME, copy.LastName, 'The new record gets the name typed in');
        Assert.areEqual('sam.clone@example.com', copy.Email);
        Assert.areEqual('Engineer', copy.Title);
        Assert.areEqual(source.OwnerId, copy.OwnerId, 'Users stay linked to the original');

        Assert.areNotEqual(originalAccount.Id, copy.AccountId, 'The Account is copied');
        Assert.areEqual(result.copiedRecordIds.get(originalAccount.Id), copy.AccountId);
        Assert.areEqual('222-222-2222', copy.Account.Phone);
        Assert.areEqual(result.copiedRecordIds.get(originalAccount.ParentId), copy.Account.ParentId, 'The parent Account is copied too');
        Assert.areEqual(PARENT_ACCOUNT_NAME, copy.Account.Parent.Name);

        Assert.areEqual(result.copiedRecordIds.get(originalManager.Id), copy.ReportsToId, 'The manager is copied');
        Assert.areEqual(copy.AccountId, copy.ReportsTo.AccountId, 'Both copied Contacts point at the same copied Account');
    }

    @IsTest
    static void getClonePlan_ListsCopiedRecordsAndLinkedLookups() {
        Contact source = getSourceContact();

        Test.startTest();
        RecordCloneService.ClonePlan plan = RecordCloneService.getClonePlan(source.Id, options(null, null));
        Test.stopTest();

        Assert.areEqual('Contact', plan.objectApiName);
        Assert.areEqual(2, plan.nameFields.size(), 'Contacts are named with First and Last Name');
        Assert.areEqual('FirstName', plan.nameFields[0].apiName);
        Assert.isFalse(plan.nameFields[0].required);
        Assert.areEqual('LastName', plan.nameFields[1].apiName);
        Assert.isTrue(plan.nameFields[1].required);
        Assert.areEqual(CONTACT_LAST_NAME, plan.nameFields[1].currentValue);
        Assert.areEqual(4, plan.records.size());
        Assert.areEqual(source.Id, plan.records[0].sourceId, 'The record itself is listed first');
        Assert.areEqual(0, plan.records[0].depth);

        Boolean ownerLinked = false;
        for (RecordCloneService.LinkedReference linked : plan.linkedReferences) {
            if (linked.fromRecordId == source.Id && linked.fieldApiName == 'OwnerId') {
                ownerLinked = true;
                Assert.areEqual(RecordCloneService.REASON_USER_GROUP, linked.reason);
                Assert.areEqual(source.OwnerId, linked.targetId);
            }
        }
        Assert.isTrue(ownerLinked, 'The owner is listed as a linked lookup');
        Assert.areEqual(0, [SELECT COUNT() FROM Contact WHERE LastName = :CONTACT_LAST_NAME AND Id != :source.Id], 'The plan changes nothing');
    }

    @IsTest
    static void cloneRecord_DepthZeroCopiesOnlyTheRecord() {
        Contact source = getSourceContact();
        Contact original = [SELECT AccountId, ReportsToId FROM Contact WHERE Id = :source.Id];

        Test.startTest();
        RecordCloneService.CloneResult result = RecordCloneService.cloneRecord(source.Id, options(0, null));
        Test.stopTest();

        Assert.areEqual(1, result.copiedCount);
        Contact copy = [SELECT AccountId, ReportsToId FROM Contact WHERE Id = :result.newRecordId];
        Assert.areEqual(original.AccountId, copy.AccountId, 'Lookups beyond the depth limit stay linked');
        Assert.areEqual(original.ReportsToId, copy.ReportsToId);
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Name = :ACCOUNT_NAME]);
    }

    @IsTest
    static void cloneRecord_LinkedObjectsAreNotCopied() {
        Contact source = getSourceContact();
        Contact original = [SELECT AccountId FROM Contact WHERE Id = :source.Id];

        Test.startTest();
        RecordCloneService.ClonePlan plan = RecordCloneService.getClonePlan(source.Id, options(null, new Set<String>{ 'account' }));
        RecordCloneService.CloneResult result = RecordCloneService.cloneRecord(source.Id, options(null, new Set<String>{ ' Account ' }));
        Test.stopTest();

        //The Contact and its manager
        Assert.areEqual(2, result.copiedCount);
        Assert.areEqual(original.AccountId, [SELECT AccountId FROM Contact WHERE Id = :result.newRecordId].AccountId);
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Name = :ACCOUNT_NAME]);

        Boolean accountLinked = false;
        for (RecordCloneService.LinkedReference linked : plan.linkedReferences) {
            if (linked.fieldApiName == 'AccountId' && linked.fromRecordId == source.Id) {
                accountLinked = true;
                Assert.areEqual(RecordCloneService.REASON_CONFIGURED, linked.reason);
                Assert.areEqual(ACCOUNT_NAME, linked.targetName);
            }
        }
        Assert.isTrue(accountLinked, 'The Account is listed as linked');
    }

    @IsTest
    static void cloneRecord_TooManyRecordsThrows() {
        Contact source = getSourceContact();
        RecordCloneService.maxRecords = 1;

        Test.startTest();
        try {
            RecordCloneService.cloneRecord(source.Id, options(null, null));
            Assert.fail('Expected an exception when too many records would be copied');
        } catch (RecordCloneService.RecordCloneException e) {
            Assert.isTrue(e.getMessage().contains('More than 1 records'), e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Contact WHERE LastName = :CONTACT_LAST_NAME]);
    }

    @IsTest
    static void cloneRecord_UsesNameFieldForNamedObjects() {
        Account account = [SELECT Id FROM Account WHERE Name = :ACCOUNT_NAME];
        RecordCloneService.CloneOptions options = new RecordCloneService.CloneOptions();
        options.maxDepth = 0;
        options.newRecordNames = new Map<String, String>{ 'name' => '  Clone Renamed Office  ' };

        Test.startTest();
        RecordCloneService.ClonePlan plan = RecordCloneService.getClonePlan(account.Id, options);
        RecordCloneService.CloneResult result = RecordCloneService.cloneRecord(account.Id, options);
        Test.stopTest();

        Assert.areEqual(1, plan.nameFields.size());
        Assert.areEqual('Name', plan.nameFields[0].apiName);
        Assert.areEqual(ACCOUNT_NAME, plan.nameFields[0].currentValue);
        Account copy = [SELECT Name, Phone FROM Account WHERE Id = :result.newRecordId];
        Assert.areEqual('Clone Renamed Office', copy.Name);
        Assert.areEqual('222-222-2222', copy.Phone);
    }

    @IsTest
    static void cloneRecord_RejectsMissingOrInvalidNames() {
        Contact source = getSourceContact();
        RecordCloneService.CloneOptions missingName = options(null, null);
        missingName.newRecordNames = new Map<String, String>{ 'FirstName' => 'Sam', 'LastName' => ' ' };
        RecordCloneService.CloneOptions otherField = options(null, null);
        otherField.newRecordNames.put('Email', 'hacked@example.com');

        Test.startTest();
        try {
            RecordCloneService.cloneRecord(source.Id, missingName);
            Assert.fail('Expected an exception without a Last Name');
        } catch (RecordCloneService.RecordCloneException e) {
            Assert.isTrue(e.getMessage().contains('Last Name'), e.getMessage());
        }
        try {
            RecordCloneService.cloneRecord(source.Id, otherField);
            Assert.fail('Expected an exception when setting a field other than the name');
        } catch (RecordCloneService.RecordCloneException e) {
            Assert.isTrue(e.getMessage().contains('email'), e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Contact WHERE LastName = :COPY_LAST_NAME]);
    }

    @IsTest
    static void getClonePlan_ListsChildRelationshipsWithRecords() {
        Account account = [SELECT Id FROM Account WHERE Name = :ACCOUNT_NAME];
        insert new Opportunity(Name = 'Clone Child Opportunity', StageName = 'Prospecting', CloseDate = Date.today(), AccountId = account.Id);

        Test.startTest();
        RecordCloneService.ClonePlan plan = RecordCloneService.getClonePlan(account.Id, new RecordCloneService.CloneOptions());
        Test.stopTest();

        Map<String, RecordCloneService.ChildRelationshipSummary> relationshipsByKey = new Map<String, RecordCloneService.ChildRelationshipSummary>();
        for (RecordCloneService.ChildRelationshipSummary relationship : plan.childRelationships) {
            relationshipsByKey.put(relationship.key, relationship);
        }
        Assert.areEqual(2, relationshipsByKey.get('Contact.AccountId').count);
        Assert.areEqual(1, relationshipsByKey.get('Opportunity.AccountId').count);
        Assert.isFalse(relationshipsByKey.containsKey('Case.AccountId'), 'Relationships without records are not listed');
        Assert.isFalse(relationshipsByKey.containsKey('AccountContactRelation.AccountId'), 'Excluded objects are not listed');
    }

    @IsTest
    static void cloneRecord_CopiesSelectedChildRecords() {
        Account account = [SELECT Id, ParentId FROM Account WHERE Name = :ACCOUNT_NAME];
        insert new Opportunity(Name = 'Clone Child Opportunity', StageName = 'Prospecting', CloseDate = Date.today(), AccountId = account.Id);
        Contact source = getSourceContact();
        Contact manager = [SELECT Id FROM Contact WHERE LastName = :MANAGER_LAST_NAME];

        RecordCloneService.CloneOptions options = new RecordCloneService.CloneOptions();
        options.newRecordNames = new Map<String, String>{ 'Name' => 'Clone Account Copy' };
        options.childRelationships = new Set<String>{ 'contact.accountid' };

        Test.startTest();
        RecordCloneService.CloneResult result = RecordCloneService.cloneRecord(account.Id, options);
        Test.stopTest();

        //The Account, its parent Account and both Contacts - not the Opportunity
        Assert.areEqual(4, result.copiedCount);
        Assert.areEqual(1, [SELECT COUNT() FROM Opportunity WHERE Name = 'Clone Child Opportunity']);

        List<Contact> copies = [SELECT Id, LastName, AccountId, ReportsToId FROM Contact WHERE AccountId = :result.newRecordId];
        Assert.areEqual(2, copies.size(), 'Both Contacts are copied onto the new Account');
        Assert.areEqual(2, [SELECT COUNT() FROM Contact WHERE AccountId = :account.Id], 'The original Contacts are untouched');
        for (Contact copy : copies) {
            if (copy.LastName == CONTACT_LAST_NAME) {
                Assert.areEqual(result.copiedRecordIds.get(manager.Id), copy.ReportsToId, 'Copied Contacts report to the copied manager');
            }
        }
        Assert.areEqual(result.copiedRecordIds.get(source.Id), [SELECT Id FROM Contact WHERE Id = :result.copiedRecordIds.get(source.Id)].Id);
        Assert.areEqual(result.copiedRecordIds.get(account.ParentId), [SELECT ParentId FROM Account WHERE Id = :result.newRecordId].ParentId);
    }

    @IsTest
    static void cloneRecord_RejectsUnknownChildRelationships() {
        Account account = [SELECT Id FROM Account WHERE Name = :ACCOUNT_NAME];
        RecordCloneService.CloneOptions options = new RecordCloneService.CloneOptions();
        options.newRecordNames = new Map<String, String>{ 'Name' => 'Clone Account Copy' };
        options.childRelationships = new Set<String>{ 'AccountContactRelation.AccountId' };

        Test.startTest();
        try {
            RecordCloneService.cloneRecord(account.Id, options);
            Assert.fail('Expected an exception for a relationship that is not offered');
        } catch (RecordCloneService.RecordCloneException e) {
            Assert.isTrue(e.getMessage().contains('AccountContactRelation.AccountId'), e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void isMasterDetail_DetectsStandardDetailRelationships() {
        Assert.isTrue(RecordCloneService.isMasterDetail(OpportunityLineItem.OpportunityId.getDescribe()),
            'OpportunityLineItem is a detail of Opportunity');
        Assert.isFalse(RecordCloneService.isMasterDetail(Contact.AccountId.getDescribe()),
            'Contact.AccountId is an ordinary lookup');
        Assert.isFalse(RecordCloneService.isMasterDetail(Account.ParentId.getDescribe()));
    }

    @IsTest
    static void cloneRecord_KeptLookupPointsAtTheOriginal() {
        Contact source = getSourceContact();
        Contact manager = [SELECT Id FROM Contact WHERE LastName = :MANAGER_LAST_NAME];
        Account originalAccount = [SELECT Id FROM Account WHERE Name = :ACCOUNT_NAME];
        RecordCloneService.CloneOptions options = options(null, null);
        //Only the Contact's own Account lookup - the manager's still copies the Account
        options.keepLookups = new Set<String>{ source.Id + '.AccountId' };

        Test.startTest();
        RecordCloneService.ClonePlan plan = RecordCloneService.getClonePlan(source.Id, options);
        RecordCloneService.CloneResult result = RecordCloneService.cloneRecord(source.Id, options);
        Test.stopTest();

        Map<String, RecordCloneService.LookupChoice> choicesByKey = new Map<String, RecordCloneService.LookupChoice>();
        for (RecordCloneService.LookupChoice choice : plan.lookupChoices) {
            choicesByKey.put(choice.key, choice);
        }
        Assert.isFalse(choicesByKey.get(source.Id + '.AccountId').copy, 'The kept lookup is listed as using the original');
        Assert.areEqual(originalAccount.Id, choicesByKey.get(source.Id + '.AccountId').targetId);
        Assert.isTrue(choicesByKey.get(manager.Id + '.AccountId').copy);
        Assert.isTrue(choicesByKey.get(source.Id + '.ReportsToId').copy);
        Assert.isFalse(choicesByKey.containsKey(source.Id + '.OwnerId'), 'Users can only stay linked, so there is no choice');

        //Contact, manager, Account (through the manager) and parent Account
        Assert.areEqual(4, result.copiedCount);
        Contact copy = [SELECT AccountId, ReportsTo.AccountId FROM Contact WHERE Id = :result.newRecordId];
        Assert.areEqual(originalAccount.Id, copy.AccountId, 'The kept lookup uses the original Account');
        Assert.areEqual(result.copiedRecordIds.get(originalAccount.Id), copy.ReportsTo.AccountId, 'The manager copy still gets a copied Account');
    }

    @IsTest
    static void cloneRecord_KeepingEveryLookupSkipsTheRecord() {
        Contact source = getSourceContact();
        Contact manager = [SELECT Id FROM Contact WHERE LastName = :MANAGER_LAST_NAME];
        Account originalAccount = [SELECT Id FROM Account WHERE Name = :ACCOUNT_NAME];
        RecordCloneService.CloneOptions options = options(null, null);
        options.keepLookups = new Set<String>{ source.Id + '.AccountId', manager.Id + '.AccountId' };

        Test.startTest();
        RecordCloneService.CloneResult result = RecordCloneService.cloneRecord(source.Id, options);
        Test.stopTest();

        //The Contact and its manager. The parent Account is only reached through the Account.
        Assert.areEqual(2, result.copiedCount);
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Name = :ACCOUNT_NAME], 'The Account is not copied');
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Name = :PARENT_ACCOUNT_NAME]);
        Contact copy = [SELECT AccountId, ReportsTo.AccountId FROM Contact WHERE Id = :result.newRecordId];
        Assert.areEqual(originalAccount.Id, copy.AccountId);
        Assert.areEqual(originalAccount.Id, copy.ReportsTo.AccountId);
    }

    @IsTest
    static void cloneRecord_CopyLookupOverridesTheDepthLimit() {
        Contact source = getSourceContact();
        Account originalAccount = [SELECT Id FROM Account WHERE Name = :ACCOUNT_NAME];
        RecordCloneService.CloneOptions options = options(0, null);
        options.copyLookups = new Set<String>{ source.Id + '.AccountId' };

        Test.startTest();
        RecordCloneService.ClonePlan plan = RecordCloneService.getClonePlan(source.Id, options);
        RecordCloneService.CloneResult result = RecordCloneService.cloneRecord(source.Id, options);
        Test.stopTest();

        Boolean reportsToListed = false;
        for (RecordCloneService.LookupChoice choice : plan.lookupChoices) {
            if (choice.key == source.Id + '.ReportsToId') {
                reportsToListed = true;
                Assert.isFalse(choice.copy, 'Past the depth limit, but it could be copied');
            }
        }
        Assert.isTrue(reportsToListed);

        //The Contact and its Account. The manager and parent Account are past the depth limit.
        Assert.areEqual(2, result.copiedCount);
        Contact copy = [SELECT AccountId, ReportsToId, Account.ParentId FROM Contact WHERE Id = :result.newRecordId];
        Assert.areEqual(result.copiedRecordIds.get(originalAccount.Id), copy.AccountId);
        Assert.areNotEqual(originalAccount.Id, copy.AccountId);
    }

    @IsTest
    static void isSystemObject_DetectsObjectsThatCantBeCopied() {
        Assert.isFalse(RecordCloneService.isSystemObject(Account.SObjectType.getDescribe()));
        Assert.isFalse(RecordCloneService.isSystemObject(Contact.SObjectType.getDescribe()));
        Assert.isTrue(RecordCloneService.isSystemObject(AccountShare.SObjectType.getDescribe()), 'Share objects');
        Assert.isTrue(RecordCloneService.isSystemObject(AccountHistory.SObjectType.getDescribe()), 'History objects');
        Assert.isTrue(RecordCloneService.isSystemObject(ActivityHistory.SObjectType.getDescribe()), 'Virtual objects');
        //Not in every org, so looked up by name
        Schema.SObjectType outgoingEmail = Schema.getGlobalDescribe().get('OutgoingEmail');
        if (outgoingEmail != null) {
            Assert.isTrue(RecordCloneService.isSystemObject(outgoingEmail.getDescribe()), 'OutgoingEmail rejects ordinary queries');
        }
    }

    @IsTest
    static void cloneRecord_CopiesCountryAndStateCodesOnly() {
        //Only applies when State and Country/Territory Picklists are enabled
        Map<String, Schema.SObjectField> contactFields = Contact.SObjectType.getDescribe().fields.getMap();
        if (!contactFields.containsKey('OtherCountryCode')) {
            return;
        }

        RecordCloneService.ObjectInfo info = new RecordCloneService.ObjectInfo(Contact.SObjectType);
        Assert.isTrue(info.fieldsByName.containsKey('OtherCountryCode'), 'The code is copied');
        Assert.isFalse(info.fieldsByName.containsKey('OtherCountry'), 'The text is filled in from the code');
        Assert.isFalse(info.fieldsByName.containsKey('MailingState'));

        Contact source = getSourceContact();
        SObject contactToUpdate = source.clone(true, false);
        contactToUpdate.put('OtherCountryCode', 'US');
        contactToUpdate.put('OtherStateCode', 'CA');
        contactToUpdate.put('MailingCountryCode', 'US');
        update contactToUpdate;

        RecordCloneService.CloneOptions options = new RecordCloneService.CloneOptions();
        options.maxDepth = 0;
        options.newRecordNames = new Map<String, String>{ 'FirstName' => 'Country', 'LastName' => COPY_LAST_NAME };

        Test.startTest();
        RecordCloneService.CloneResult result = RecordCloneService.cloneRecord(source.Id, options);
        Test.stopTest();

        SObject copy = Database.query('SELECT OtherCountryCode, OtherStateCode, MailingCountryCode FROM Contact WHERE Id = \'' + result.newRecordId + '\'');
        Assert.areEqual('US', copy.get('OtherCountryCode'));
        Assert.areEqual('CA', copy.get('OtherStateCode'));
        Assert.areEqual('US', copy.get('MailingCountryCode'));
    }

    @IsTest
    static void getClonePlan_ContactSkipsSystemObjects() {
        Contact source = getSourceContact();

        Test.startTest();
        RecordCloneService.ClonePlan plan = RecordCloneService.getClonePlan(source.Id, new RecordCloneService.CloneOptions());
        Test.stopTest();

        for (RecordCloneService.ChildRelationshipSummary relationship : plan.childRelationships) {
            Assert.isFalse(relationship.childObjectApiName.startsWithIgnoreCase('OutgoingEmail'), relationship.key);
            Assert.isFalse(relationship.childObjectApiName.endsWithIgnoreCase('Share'), relationship.key);
        }
    }

    @IsTest
    static void controller_ReturnsPlanAndCopies() {
        Contact source = getSourceContact();

        Test.startTest();
        RecordCloneService.ClonePlan plan = (RecordCloneService.ClonePlan) JSON.deserialize(
            RecordCloneController.getClonePlan(source.Id, 'Account, ,Pricebook2', 5, null, null), RecordCloneService.ClonePlan.class);
        RecordCloneService.CloneResult result = (RecordCloneService.CloneResult) JSON.deserialize(
            RecordCloneController.cloneRecord(source.Id, 'Account', null, '{"LastName":"' + COPY_LAST_NAME + '"}', null, null, null),
            RecordCloneService.CloneResult.class);
        Test.stopTest();

        Assert.areEqual(2, plan.records.size());
        Assert.areEqual(2, result.copiedCount);
        Contact copy = [SELECT FirstName, LastName FROM Contact WHERE Id = :result.newRecordId];
        Assert.areEqual(COPY_LAST_NAME, copy.LastName);
        Assert.isNull(copy.FirstName, 'A First Name left out of the request is blank on the copy');

        RecordCloneService.CloneOptions options = RecordCloneController.buildOptions('Account, ,Pricebook2', 3, null, null);
        Assert.areEqual(new Set<String>{ 'Account', 'Pricebook2' }, options.linkedObjects);
        Assert.areEqual(3, options.maxDepth);
    }

    @IsTest
    static void controller_WrapsErrors() {
        Test.startTest();
        try {
            RecordCloneController.cloneRecord(null, null, null, null, null, null, null);
            Assert.fail('Expected an exception without a record');
        } catch (AuraHandledException e) {
            Assert.areEqual('A record is required to copy.', e.getMessage());
        }
        try {
            RecordCloneController.getClonePlan(null, null, null, null, null);
            Assert.fail('Expected an exception without a record');
        } catch (AuraHandledException e) {
            Assert.areEqual('A record is required to copy.', e.getMessage());
        }
        Test.stopTest();
    }
}