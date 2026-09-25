import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import getClonePlan from '@salesforce/apex/RecordCloneController.getClonePlan';

const COPY = 'copy';
const KEEP = 'keep';

/**
 * Asks for the new record's name, whether each lookup gets a copy of its record or keeps
 * pointing at the original, and which related records to copy, before recordClone makes the copy.
 * Closes with { names: { fieldApiName: value }, childRelationships: [ 'Contact.AccountId' ],
 * keepLookups: [ key ], copyLookups: [ key ] } when Copy is clicked, or undefined when cancelled.
 */
export default class RecordCloneNameModal extends LightningModal {
    @api heading;
    //RecordCloneService.NameField list: apiName, label, currentValue, required, maxLength
    @api nameFields = [];
    //RecordCloneService.ChildRelationshipSummary list: key, childObjectLabel, fieldLabel, count
    @api childRelationships = [];
    //RecordCloneService.ClonePlan loaded by recordClone, with every lookup at its default
    @api plan;
    //recordId, linkedObjects and maxDepth, to reload the plan as lookups are switched
    @api planParams;

    values = {};
    selectedRelationships = [];

    //The plan for the current choices - starts as the plan passed in
    currentPlan;
    //LookupChoice.key -> COPY or KEEP, for the lookups the user has switched
    lookupChoices = {};
    isRefreshing = false;
    refreshError = null;
    refreshRequest = 0;

    //Start with the original record's name so it only needs editing
    connectedCallback() {
        const values = {};
        (this.nameFields || []).forEach((field) => {
            values[field.apiName] = field.currentValue ?? '';
        });
        this.values = values;
        this.currentPlan = this.plan;
    }

    get inputs() {
        return (this.nameFields || []).map((field) => ({
            ...field,
            value: this.values[field.apiName] ?? ''
        }));
    }

    get hasInputs() {
        return this.inputs.length > 0;
    }

    //Start - lookups

    get choiceOptions() {
        return [
            { label: 'Copy', value: COPY },
            { label: 'Use original', value: KEEP }
        ];
    }

    //The lookups that can go either way, grouped by the record they're on
    get lookupGroups() {
        const choices = this.currentPlan?.lookupChoices || [];
        const groups = [];
        const groupsByRecordId = {};
        choices.forEach((choice) => {
            let group = groupsByRecordId[choice.fromRecordId];
            if (!group) {
                const isRoot = choice.fromRecordId === this.currentPlan.recordId;
                group = {
                    id: choice.fromRecordId,
                    heading: isRoot ? `This ${this.currentPlan.objectLabel}` : `Copied ${choice.fromObjectLabel}: ${choice.fromRecordName}`,
                    rows: []
                };
                groupsByRecordId[choice.fromRecordId] = group;
                groups.push(group);
            }
            group.rows.push({
                key: choice.key,
                fieldLabel: choice.fieldLabel,
                targetName: choice.targetName,
                targetObjectLabel: choice.targetObjectLabel,
                value: choice.copy ? COPY : KEEP
            });
        });
        return groups;
    }

    get hasLookupGroups() {
        return this.lookupGroups.length > 0;
    }

    handleLookupChoice(event) {
        this.lookupChoices = { ...this.lookupChoices, [event.target.dataset.key]: event.detail.value };
        this.refreshPlan();
    }

    get keepLookups() {
        return Object.keys(this.lookupChoices).filter((key) => this.lookupChoices[key] === KEEP);
    }

    get copyLookups() {
        return Object.keys(this.lookupChoices).filter((key) => this.lookupChoices[key] === COPY);
    }

    //Reload the plan so lookups on records that are no longer copied drop out of the list,
    //and lookups on newly copied records appear
    async refreshPlan() {
        const request = ++this.refreshRequest;
        this.isRefreshing = true;
        this.refreshError = null;
        try {
            const plan = JSON.parse(
                await getClonePlan({ ...this.planParams, keepLookups: this.keepLookups, copyLookups: this.copyLookups })
            );
            if (request === this.refreshRequest) {
                this.currentPlan = plan;
            }
        } catch (error) {
            if (request === this.refreshRequest) {
                this.refreshError = error?.body?.message ?? error?.message ?? 'Unknown error';
            }
        } finally {
            if (request === this.refreshRequest) {
                this.isRefreshing = false;
            }
        }
    }

    //End - lookups

    //Start - related records

    get hasChildRelationships() {
        return (this.childRelationships || []).length > 0;
    }

    //Two relationships to the same object (e.g. Accounts by Parent Account) are told apart by the field
    get relationshipOptions() {
        const labelCounts = {};
        this.childRelationships.forEach((relationship) => {
            labelCounts[relationship.childObjectLabel] = (labelCounts[relationship.childObjectLabel] || 0) + 1;
        });
        return this.childRelationships.map((relationship) => {
            const suffix = labelCounts[relationship.childObjectLabel] > 1 ? ` by ${relationship.fieldLabel}` : '';
            return {
                label: `${relationship.childObjectLabel}${suffix} (${relationship.count})`,
                value: relationship.key
            };
        });
    }

    handleRelationshipChange(event) {
        this.selectedRelationships = event.detail.value;
    }

    //End - related records

    get summary() {
        const lookedUp = this.currentPlan ? this.currentPlan.records.length - 1 : 0;
        const originalCount = (this.currentPlan?.lookupChoices || []).filter((choice) => !choice.copy).length;
        let related = 0;
        this.childRelationships
            .filter((relationship) => this.selectedRelationships.includes(relationship.key))
            .forEach((relationship) => {
                related += relationship.count;
            });

        const parts = [];
        if (lookedUp > 0) {
            parts.push(`${lookedUp} record(s) it looks up to`);
        }
        if (related > 0) {
            parts.push(`${related} related record(s)`);
        }
        let summary = parts.length === 0 ? 'Only this record will be copied.' : `This record and ${parts.join(' and ')} will be copied.`;
        if (originalCount > 0) {
            summary += ` ${originalCount} lookup(s) will point at the original record.`;
        }
        if (related > 0) {
            summary += ' Records the related records look up to may be copied as well.';
        }
        return summary;
    }

    get copyDisabled() {
        return this.isRefreshing || !!this.refreshError;
    }

    handleChange(event) {
        this.values = { ...this.values, [event.target.dataset.field]: event.detail.value };
    }

    handleCancel() {
        this.close();
    }

    handleCopy() {
        const inputs = [...this.template.querySelectorAll('lightning-input')];
        const allValid = inputs.reduce((valid, input) => input.reportValidity() && valid, true);
        if (allValid) {
            this.close({
                names: this.values,
                childRelationships: this.selectedRelationships,
                keepLookups: this.keepLookups,
                copyLookups: this.copyLookups
            });
        }
    }
}
