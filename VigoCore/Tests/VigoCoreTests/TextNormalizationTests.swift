import Testing
import Foundation
@testable import VigoCore

@Suite("Plegado de texto para el buscador")
struct TextNormalizationTests {

    @Test("Acentos, mayúsculas y espacios dobles se pliegan")
    func basicFolding() {
        #expect(TextNormalization.searchFolded("Porriño") == "porrino")
        #expect(TextNormalization.searchFolded("PORRIÑO") == "porrino")
        #expect(TextNormalization.searchFolded("Praza de América  1") == "praza de america 1")
    }

    /// H-10: la puntuación del feed no sobrevivía al plegado, así que "avda florida" no
    /// encontraba "Avda. da Florida".
    @Test("La puntuación se pliega a espacio, no se conserva")
    func punctuationFolding() {
        #expect(TextNormalization.searchFolded("Avda. da Florida  117") == "avda da florida 117")
        #expect(TextNormalization.searchFolded("Rúa de Urzáiz - Príncipe") == "rua de urzaiz principe")
        #expect(TextNormalization.searchFolded("Avda. Beiramar \"Porto Pesqueiro Berbés\"")
                 == "avda beiramar porto pesqueiro berbes")
    }

    /// Los dígitos son parte de lo que se busca (números de portal), y no deben caer con
    /// el resto de la puntuación.
    @Test("Los dígitos se conservan")
    func digitsSurvive() {
        #expect(TextNormalization.searchFolded("Rúa de Barcelona  18") == "rua de barcelona 18")
    }

    @Test("H-01 · likePattern escapa % y _ para que no actúen como comodín")
    func likePatternEscapesWildcards() {
        #expect(TextNormalization.likePattern("50%") == "50\\%")
        #expect(TextNormalization.likePattern("a_b") == "a\\_b")
        #expect(TextNormalization.likePattern("100%_off") == "100\\%\\_off")
        #expect(TextNormalization.likePattern("a\\b") == "a\\\\b")
        #expect(TextNormalization.likePattern("urzaiz") == "urzaiz", "sin metacaracteres, no cambia")
    }
}
