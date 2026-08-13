pub mod book;
pub mod cast;
pub mod chapters;
pub mod chunk;
pub mod decode;
pub mod fingerprint;
pub mod focus;
pub mod genre;
pub mod meta;
pub mod relation;
pub mod repair;
pub mod romance;
pub mod source;
pub mod store;

/// Full-width ideographic space. Two of them are the canonical Chinese
/// paragraph indent, and their presence is the strongest structural signal
/// we have: indented line = body text, flush line = structure.
pub const IDEOGRAPHIC_SPACE: char = '\u{3000}';

/// Half-width variants count too: real books indent with four ASCII spaces and
/// put their titles at zero or one — so the threshold is two, not one.
pub fn is_indented(line: &str) -> bool {
    let mut it = line.chars();
    match (it.next(), it.next()) {
        (Some(IDEOGRAPHIC_SPACE), Some(IDEOGRAPHIC_SPACE)) => true,
        (Some(' '), Some(' ')) => true,
        (Some('\t'), _) => true,
        _ => false,
    }
}
