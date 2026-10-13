/**
 * Pluggable notes extraction. Implemented by NotesExtractionAI (Prompt Builder, package directory
 * force-app-ai), loaded with Type.forName so the core deploys without Einstein generative AI.
 */
public interface NotesExtractor {
    NotesExtractionService.Result extract(String notes, Date today);
}
