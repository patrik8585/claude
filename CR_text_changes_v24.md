# CR text changes – Actions button and Insight tab (mockup v24)

Replacement wording for the CR. I did not have the CR file, so the section names below match your macro requirement text. Please map them to your CR numbering.

## 1. Actions button ("•••") next to Start call

Replace the current actions paragraph with:

> The "•••" button next to Start call opens a menu with these actions, in this order:
> 1. **Share box**
> 2. **Plan a call** – opens the calendar, where the user picks a day and a free slot to plan a call with the HCP/HCO.
> 3. **Open in Salesforce (online)** – always the last option.
>
> Removed from the list:
> - **Quick share** (still available in the Pitcher top bar, which is unchanged).
> - **Questionnaire** (moved to the Insight tab, sub-tab Questionnaire).
> - **TBD** placeholder (no further actions planned).
>
> The "list of useful actions" open point for @Levent NAZLI is closed.

## 2. Insight tab – sub-tabs

Replace "Insight tab framework with 2 sub-tabs, General and Segment" with:

> The Insight tab has 5 sub-tabs, in this order: **General, Segment, Affiliation, Questionnaire, Sample**. The Related sub-tab stays out of scope.
> - **General** (Account fields) and **Segment** (Account Segment records): unchanged, driven by `Account_Insight_Card__mdt` / `Account_Insight_Range__mdt`.
> - **Affiliation, Questionnaire, Sample**: fixed sub-tabs, always shown on the HCP and HCO page. They show standard data and need no card metadata.

### 2.1 Affiliation (new)

> Shows the affiliations of the account, between HCP and HCP and between HCP and HCO.
> Columns:
> - **From** and **To** – each can be an HCP or an HCO. Both are always mandatory: an affiliation without From and To is not allowed.
> - **Decision maker** – multipicklist with the values *Discharge Decision Maker* and *Product Decision Maker*. A row can have both, or none. Read-only.
> - **Relationship type** – *Soft* or *Hard*. Read-only.
>
> Actions:
> - **+ New affiliation** button: the user picks From and To (both mandatory, and they must be different). The new affiliation is created as *Soft*.
> - **Hard** affiliations: From and To cannot be changed (lock icon).
> - **Soft** affiliations: From and To can be changed (pencil, Save / Cancel).

### 2.2 Questionnaire (new)

> Lists the questionnaires assigned to the HCP/HCO.
> Columns:
> - **Questionnaire**
> - **Status** – Answered / Not answered.
> - **Mandatory** – Mandatory / Optional.
> - **Assigned / answered date**
> - **Action** – **Start** button on questionnaires not yet answered, to launch the questionnaire; **View answers** on answered ones.
>
> A summary above the list shows "x of y answered" and "n mandatory open". A filter switches between All, Open and Answered. The Questionnaire entry is removed from the Actions menu.

### 2.3 Sample (new)

> Shows, per product, the sample limit and the quantity already used or delivered **for the current year**. Limits are annual, so the quantities restart from 0 every year.
> Columns:
> - **Product**
> - **Annual limit** (current year)
> - **Delivered** (current year)
> - **Remaining** – shows "limit reached" at 0.
>
> There is no usage chart: the numbers are enough.

### 2.4 Segment – read-only letter

> In the Segment grid, **Segment letter** is read-only. NOB and CL stay editable inline. In `Account_Insight_Card__mdt`, the Segment letter column has `Is_Editable__c = false`.

## 3. Metadata impact

- `Account_Insight_Card__mdt.Sub_Tab__c` stays **General / Segment** only, because the three new sub-tabs are not card-driven.
- The 6-step resolution does not apply to Affiliation, Questionnaire and Sample. They are the same for every CBU, Team and Record type.
- If the business wants to hide a sub-tab per CBU, we need a switch such as `Account_Insight_Subtab__mdt`. This is not in the current scope.

## 4. Open points to confirm

1. **Source objects** for the three sub-tabs: affiliation object, questionnaire assignment object, and where the product sample limit and delivered quantity are stored.
2. **Decision maker**: the mockup shows it per affiliation record, read-only. Who sets it (integration, back office)?
3. **Sample period**: confirmed annual. Does the year mean the calendar year, or a fiscal year?
4. **Plan a call**: does the calendar create a Pitcher call or a calendar event? The mockup only shows the picker.
5. **Questionnaire Start**: confirm it opens the existing Pitcher questionnaire, and whether mandatory ones must block anything (for example the call).
6. **Sub-tabs on HCO**: Questionnaire and Sample are shown on both pages. Confirm they are needed on HCO.
7. **Line 3 GO Rating** (AT, Adults): I only removed it from Insight → General. The header demo still shows it. Remove it there too?
