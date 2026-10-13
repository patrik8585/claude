/**
 * Phase 3 "Extract with AI": calls the Prompt Builder flex template (default HCP_Notes_Extraction,
 * inputs "notes" and "today") and maps its JSON answer to NotesExtractionService.Result.
 *
 * Deployed separately (package directory force-app-ai) after Einstein generative AI and the template
 * are set up. NotesExtractionService.extractSmart() loads it with Type.forName and falls back to the
 * rule-based extraction on any exception, so a missing template or an Einstein outage never blocks a rep.
 */
public with sharing class NotesExtractionAI implements NotesExtractor {
    public NotesExtractionService.Result extract(String notes, Date today) {
        String templateName = ConsentCaptureConfig.settings().Prompt_Template__c;
        if (String.isBlank(templateName)) {
            templateName = NotesExtractionService.DEFAULT_TEMPLATE;
        }
        ConnectApi.WrappedValue notesValue = new ConnectApi.WrappedValue();
        notesValue.value = notes;
        ConnectApi.WrappedValue todayValue = new ConnectApi.WrappedValue();
        todayValue.value = String.valueOf(today);

        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:notes' => notesValue, 'Input:today' => todayValue };
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(templateName, input);
        if (output == null || output.generations == null || output.generations.isEmpty()) {
            return null;
        }
        return NotesExtractionService.fromJson(output.generations[0].text, today);
    }
}
