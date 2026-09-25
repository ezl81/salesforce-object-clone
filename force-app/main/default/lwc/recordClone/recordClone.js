import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getClonePlan from '@salesforce/apex/RecordCloneController.getClonePlan';
import cloneRecord from '@salesforce/apex/RecordCloneController.cloneRecord';
import RecordCloneNameModal from 'c/recordCloneNameModal';

export default class RecordClone extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;
    @api cardTitle;
    @api linkedObjects;
    @api maxDepth;
    @api showPreview;

    //RecordCloneService.ClonePlan from Apex
    plan = null;

    showLinked = false;
    isLoading = false;
    errorMessage = null;

    //The plan is always loaded because it holds the name fields; showPreview only controls whether it's displayed
    connectedCallback() {
        this.loadPlan();
    }

    get title() {
        return this.cardTitle || 'Copy Record';
    }

    //Blank design attributes come through as undefined or '', which Apex needs as null
    get depthParam() {
        return this.maxDepth === undefined || this.maxDepth === null || this.maxDepth === '' ? null : Number(this.maxDepth);
    }

    get apexParams() {
        return { recordId: this.recordId, linkedObjects: this.linkedObjects || '', maxDepth: this.depthParam };
    }

    //Start - preview

    async loadPlan() {
        this.isLoading = true;
        this.errorMessage = null;
        try {
            this.plan = JSON.parse(await getClonePlan(this.apexParams));
        } catch (error) {
            this.plan = null;
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleRefresh() {
        this.loadPlan();
    }

    get showPlanDetails() {
        return this.showPreview && !!this.plan;
    }

    get copyRows() {
        if (!this.plan) {
            return [];
        }
        return this.plan.records.map((record) => ({
            ...record,
            url: `/lightning/r/${record.sourceId}/view`,
            isRoot: record.sourceId === this.plan.recordId,
            pathLabel: record.sourceId === this.plan.recordId ? 'This record' : record.path
        }));
    }

    get copyCount() {
        return this.plan ? this.plan.records.length : 0;
    }

    get copySummary() {
        const related = this.copyCount - 1;
        if (related <= 0) {
            return 'Only this record will be copied.';
        }
        return `This record and ${related} record(s) it looks up to will be copied.`;
    }

    get linkedRows() {
        if (!this.plan) {
            return [];
        }
        return this.plan.linkedReferences.map((linked, index) => ({
            ...linked,
            key: `${linked.fromRecordId}-${linked.fieldApiName}-${index}`,
            targetUrl: `/lightning/r/${linked.targetId}/view`
        }));
    }

    get linkedCount() {
        return this.plan ? this.plan.linkedReferences.length : 0;
    }

    get hasLinked() {
        return this.linkedCount > 0;
    }

    get linkedToggleLabel() {
        return `${this.showLinked ? 'Hide' : 'Show'} ${this.linkedCount} lookup(s) kept linked to the original record`;
    }

    get linkedToggleIcon() {
        return this.showLinked ? 'utility:chevrondown' : 'utility:chevronright';
    }

    handleToggleLinked() {
        this.showLinked = !this.showLinked;
    }

    //End - preview

    //Start - copy

    get copyDisabled() {
        return this.isLoading || !this.plan;
    }

    //Ask for the new record's name, whether each lookup is copied or keeps the original,
    //and which related records to copy, then copy
    async handleCopy() {
        const choices = await RecordCloneNameModal.open({
            size: 'small',
            label: `Copy ${this.plan.recordName}`,
            heading: `Copy ${this.plan.recordName}`,
            nameFields: this.plan.nameFields,
            childRelationships: this.plan.childRelationships,
            plan: this.plan,
            planParams: this.apexParams
        });
        //Cancelled or closed
        if (!choices) {
            return;
        }

        this.isLoading = true;
        this.errorMessage = null;
        try {
            const result = JSON.parse(
                await cloneRecord({
                    ...this.apexParams,
                    newRecordNames: JSON.stringify(choices.names),
                    childRelationships: choices.childRelationships,
                    keepLookups: choices.keepLookups,
                    copyLookups: choices.copyLookups
                })
            );

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Record copied',
                    message: `${result.copiedCount} record(s) created.`,
                    variant: 'success'
                })
            );

            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: result.newRecordId,
                    actionName: 'view'
                }
            });
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    //End - copy

    handleError(err) {
        this.errorMessage = this.reduceError(err);
        console.log('Error = ' + JSON.stringify(err));
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        } else if (error?.body?.message) {
            return error.body.message;
        }
        return error?.message ?? 'Unknown error';
    }
}