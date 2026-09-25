import { api } from 'lwc';
import LightningModal from 'lightning/modal';

/**
 * Asks for the new record's name, and which related records to copy with it,
 * before recordClone makes the copy.
 * Closes with { names: { fieldApiName: value }, childRelationships: [ 'Contact.AccountId' ] }
 * when Copy is clicked, or undefined when cancelled.
 */
export default class RecordCloneNameModal extends LightningModal {
    @api heading;
    //RecordCloneService.NameField list: apiName, label, currentValue, required, maxLength
    @api nameFields = [];
    //RecordCloneService.ChildRelationshipSummary list: key, childObjectLabel, fieldLabel, count
    @api childRelationships = [];
    //Number of records copied without any related records (the record and its lookups)
    @api baseCount = 1;

    values = {};
    selectedRelationships = [];

    //Start with the original record's name so it only needs editing
    connectedCallback() {
        const values = {};
        (this.nameFields || []).forEach((field) => {
            values[field.apiName] = field.currentValue ?? '';
        });
        this.values = values;
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

    get summary() {
        const lookedUp = this.baseCount - 1;
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
        if (parts.length === 0) {
            return 'Only this record will be copied.';
        }
        return `This record and ${parts.join(' and ')} will be copied. Records the related records look up to may be copied as well.`;
    }

    //End - related records

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
            this.close({ names: this.values, childRelationships: this.selectedRelationships });
        }
    }
}