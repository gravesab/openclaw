import Foundation
import SwiftUI

/// Presentation-only DEV fixture metadata. It is never an authenticated tenant context.
struct FixturePresentationContext: Equatable, Sendable {
    let displayName: String
    let environment: String
    let statusLabel: String

    static let preview = FixturePresentationContext(
        displayName: "RedBud Ranch fixture",
        environment: "DEV fixture",
        statusLabel: "No authenticated tenant session"
    )
}

struct LivestockBuildStamp: Equatable, Sendable {
    let name: String
    let environment: String
    let version: String
    let build: String

    var headerDetail: String { "Version \(version) · Build \(build)" }
    var isProduction: Bool { environment == "PROD" }
    /// User-facing store name. PROD drops the DEV prefix; the live ticket and server stay the same.
    var databaseLabel: String { isProduction ? "livestock database" : "DEV database" }
    var serverLabel: String { isProduction ? "livestock server" : "livestock DEV server" }

    static var current: LivestockBuildStamp {
        resolved(info: Bundle.main.infoDictionary, bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// DEV and PROD both keep the bundle version and build. The environment comes from the app, not a fixed label.
    static func resolved(info: [String: Any]?, bundleIdentifier: String?) -> LivestockBuildStamp {
        let version = text(info?["CFBundleShortVersionString"]) ?? "0.1.0"
        let build = text(info?["CFBundleVersion"]) ?? "1"
        let declared = text(info?["LivestockEnvironment"])?.uppercased()
        let environment: String
        if let declared, declared == "DEV" || declared == "PROD" {
            environment = declared
        } else if bundleIdentifier?.localizedCaseInsensitiveContains(".dev") == true {
            environment = "DEV"
        } else {
            environment = "PROD"
        }
        return LivestockBuildStamp(
            name: "Livestock \(environment)",
            environment: environment,
            version: version,
            build: build
        )
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AnimalCategory: String, CaseIterable, Identifiable, Sendable {
    case liveStock, pets

    var id: String { rawValue }
    var label: String {
        switch self {
        case .liveStock: "Current livestock/group"
        case .pets: "Current pets"
        }
    }
    var addLabel: String {
        switch self {
        case .liveStock: "Add livestock/group"
        case .pets: "Add pets"
        }
    }
    var speciesChoices: [Species] {
        switch self {
        case .liveStock: Species.pickerChoices
        case .pets: [.pet]
        }
    }

    func includes(_ species: Species) -> Bool {
        species == .pet ? self == .pets : self == .liveStock
    }
}

enum PetKind: String, CaseIterable, Identifiable, Sendable {
    case dog, cat, bird, reptile, other

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    static func acceptsCode(_ code: String) -> Bool {
        allCases.contains { $0.rawValue == code }
    }
}

enum Species: String, CaseIterable, Identifiable, Sendable {
    case cattle, dairyCow = "dairy_cow", bison, chicken, goat, horse, pet, pig, sheep

    var id: String { rawValue }
    static let pickerChoices: [Species] = [.cattle, .dairyCow, .bison, .chicken, .goat, .horse, .pig, .sheep]

    var label: String {
        switch self {
        case .cattle: "Beef cattle"
        case .dairyCow: "Dairy cow"
        case .bison: "Bison"
        case .goat: "Goats"
        case .sheep: "Sheep"
        case .chicken: "Chickens"
        case .pig: "Pigs"
        case .horse: "Horses"
        case .pet: "Pets"
        }
    }
}

enum ProductionType: String, CaseIterable, Identifiable, Sendable {
    case beef, breeding, broiler, companion, dairy, layer
    case forSale = "for_sale"
    case personalMeat = "personal_meat"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .forSale: "For sale"
        case .personalMeat: "Personal meat production"
        default: rawValue.capitalized
        }
    }
}

struct Breed: Identifiable, Equatable, Hashable, Sendable {
    let code: String
    let label: String
    let species: Species
    var id: String { "\(species.rawValue).\(code)" }
}

enum LivestockCatalog {
    static let durableSpeciesCodes: Set<String> = Set(Species.allCases.map(\.rawValue))

    static let breeds = [
        Breed(code: "angus", label: "Angus", species: .cattle),
        Breed(code: "ayrshire", label: "Ayrshire", species: .cattle),
        Breed(code: "brahman", label: "Brahman", species: .cattle),
        Breed(code: "brangus", label: "Brangus", species: .cattle),
        Breed(code: "brown_swiss", label: "Brown Swiss", species: .cattle),
        Breed(code: "charolais", label: "Charolais", species: .cattle),
        Breed(code: "gelbvieh", label: "Gelbvieh", species: .cattle),
        Breed(code: "guernsey", label: "Guernsey", species: .cattle),
        Breed(code: "hereford", label: "Hereford", species: .cattle),
        Breed(code: "highland", label: "Highland", species: .cattle),
        Breed(code: "holstein", label: "Holstein", species: .cattle),
        Breed(code: "jersey", label: "Jersey", species: .cattle),
        Breed(code: "limousin", label: "Limousin", species: .cattle),
        Breed(code: "maine_anjou", label: "Maine-Anjou", species: .cattle),
        Breed(code: "red_angus", label: "Red Angus", species: .cattle),
        Breed(code: "shorthorn", label: "Shorthorn", species: .cattle),
        Breed(code: "simmental", label: "Simmental", species: .cattle),
        Breed(code: "texas_longhorn", label: "Texas Longhorn", species: .cattle),
        Breed(code: "wagyu", label: "Wagyu", species: .cattle),
        Breed(code: "beefmaster", label: "Beefmaster", species: .cattle),
        Breed(code: "belted_galloway", label: "Belted Galloway", species: .cattle),
        Breed(code: "chianina", label: "Chianina", species: .cattle),
        Breed(code: "corriente", label: "Corriente", species: .cattle),
        Breed(code: "devon", label: "Devon", species: .cattle),
        Breed(code: "dexter", label: "Dexter", species: .cattle),
        Breed(code: "dutch_belted", label: "Dutch Belted", species: .cattle),
        Breed(code: "galloway", label: "Galloway", species: .cattle),
        Breed(code: "milking_shorthorn", label: "Milking Shorthorn", species: .cattle),
        Breed(code: "murray_grey", label: "Murray Grey", species: .cattle),
        Breed(code: "normande", label: "Normande", species: .cattle),
        Breed(code: "piedmontese", label: "Piedmontese", species: .cattle),
        Breed(code: "pinzgauer", label: "Pinzgauer", species: .cattle),
        Breed(code: "red_poll", label: "Red Poll", species: .cattle),
        Breed(code: "salers", label: "Salers", species: .cattle),
        Breed(code: "santa_gertrudis", label: "Santa Gertrudis", species: .cattle),
        Breed(code: "south_devon", label: "South Devon", species: .cattle),
        Breed(code: "tarentaise", label: "Tarentaise", species: .cattle),
        Breed(code: "ayrshire", label: "Ayrshire", species: .dairyCow),
        Breed(code: "brown_swiss", label: "Brown Swiss", species: .dairyCow),
        Breed(code: "canadienne", label: "Canadienne", species: .dairyCow),
        Breed(code: "danish_red", label: "Danish Red", species: .dairyCow),
        Breed(code: "dutch_belted", label: "Dutch Belted", species: .dairyCow),
        Breed(code: "guernsey", label: "Guernsey", species: .dairyCow),
        Breed(code: "holstein", label: "Holstein", species: .dairyCow),
        Breed(code: "illawarra", label: "Illawarra", species: .dairyCow),
        Breed(code: "jersey", label: "Jersey", species: .dairyCow),
        Breed(code: "kerry", label: "Kerry", species: .dairyCow),
        Breed(code: "milking_shorthorn", label: "Milking Shorthorn", species: .dairyCow),
        Breed(code: "montbeliarde", label: "Montbéliarde", species: .dairyCow),
        Breed(code: "normande", label: "Normande", species: .dairyCow),
        Breed(code: "norwegian_red", label: "Norwegian Red", species: .dairyCow),
        Breed(code: "randall", label: "Randall", species: .dairyCow),
        Breed(code: "swedish_red", label: "Swedish Red", species: .dairyCow),
        Breed(code: "american_bison", label: "American Bison", species: .bison),
        Breed(code: "wood_bison", label: "Wood Bison", species: .bison),
        Breed(code: "beefalo", label: "Beefalo", species: .bison),
        Breed(code: "alpine", label: "Alpine", species: .goat),
        Breed(code: "angora", label: "Angora", species: .goat),
        Breed(code: "boer", label: "Boer", species: .goat),
        Breed(code: "kiko", label: "Kiko", species: .goat),
        Breed(code: "lamancha", label: "LaMancha", species: .goat),
        Breed(code: "nigerian_dwarf", label: "Nigerian Dwarf", species: .goat),
        Breed(code: "nubian", label: "Nubian", species: .goat),
        Breed(code: "oberhasli", label: "Oberhasli", species: .goat),
        Breed(code: "pygmy", label: "Pygmy", species: .goat),
        Breed(code: "saanen", label: "Saanen", species: .goat),
        Breed(code: "spanish", label: "Spanish", species: .goat),
        Breed(code: "toggenburg", label: "Toggenburg", species: .goat),
        Breed(code: "kalahari_red", label: "Kalahari Red", species: .goat),
        Breed(code: "kinder", label: "Kinder", species: .goat),
        Breed(code: "myotonic", label: "Myotonic", species: .goat),
        Breed(code: "savanna", label: "Savanna", species: .goat),
        Breed(code: "columbia", label: "Columbia", species: .sheep),
        Breed(code: "dorper", label: "Dorper", species: .sheep),
        Breed(code: "dorset", label: "Dorset", species: .sheep),
        Breed(code: "hampshire", label: "Hampshire", species: .sheep),
        Breed(code: "katahdin", label: "Katahdin", species: .sheep),
        Breed(code: "merino", label: "Merino", species: .sheep),
        Breed(code: "polypay", label: "Polypay", species: .sheep),
        Breed(code: "rambouillet", label: "Rambouillet", species: .sheep),
        Breed(code: "romney", label: "Romney", species: .sheep),
        Breed(code: "southdown", label: "Southdown", species: .sheep),
        Breed(code: "suffolk", label: "Suffolk", species: .sheep),
        Breed(code: "texel", label: "Texel", species: .sheep),
        Breed(code: "barbados_blackbelly", label: "Barbados Blackbelly", species: .sheep),
        Breed(code: "bluefaced_leicester", label: "Bluefaced Leicester", species: .sheep),
        Breed(code: "border_leicester", label: "Border Leicester", species: .sheep),
        Breed(code: "cheviot", label: "Cheviot", species: .sheep),
        Breed(code: "clun_forest", label: "Clun Forest", species: .sheep),
        Breed(code: "corriedale", label: "Corriedale", species: .sheep),
        Breed(code: "finnsheep", label: "Finnsheep", species: .sheep),
        Breed(code: "gulf_coast", label: "Gulf Coast Native", species: .sheep),
        Breed(code: "icelandic_sheep", label: "Icelandic", species: .sheep),
        Breed(code: "jacob", label: "Jacob", species: .sheep),
        Breed(code: "lincoln", label: "Lincoln", species: .sheep),
        Breed(code: "navajo_churro", label: "Navajo-Churro", species: .sheep),
        Breed(code: "oxford", label: "Oxford", species: .sheep),
        Breed(code: "shetland_sheep", label: "Shetland", species: .sheep),
        Breed(code: "shropshire", label: "Shropshire", species: .sheep),
        Breed(code: "st_croix", label: "St. Croix", species: .sheep),
        Breed(code: "tunis", label: "Tunis", species: .sheep),
        Breed(code: "ameraucana", label: "Ameraucana", species: .chicken),
        Breed(code: "ancona", label: "Ancona", species: .chicken),
        Breed(code: "chicken_andalusian", label: "Andalusian", species: .chicken),
        Breed(code: "araucana", label: "Araucana", species: .chicken),
        Breed(code: "australorp", label: "Australorp", species: .chicken),
        Breed(code: "barnevelder", label: "Barnevelder", species: .chicken),
        Breed(code: "brahma", label: "Brahma", species: .chicken),
        Breed(code: "buckeye", label: "Buckeye", species: .chicken),
        Breed(code: "buttercup", label: "Sicilian Buttercup", species: .chicken),
        Breed(code: "campine", label: "Campine", species: .chicken),
        Breed(code: "chantecler", label: "Chantecler", species: .chicken),
        Breed(code: "cochin", label: "Cochin", species: .chicken),
        Breed(code: "cornish", label: "Cornish", species: .chicken),
        Breed(code: "cornish_cross", label: "Cornish Cross", species: .chicken),
        Breed(code: "crevecoeur", label: "Crevecoeur", species: .chicken),
        Breed(code: "cubalaya", label: "Cubalaya", species: .chicken),
        Breed(code: "delaware", label: "Delaware", species: .chicken),
        Breed(code: "dominique", label: "Dominique", species: .chicken),
        Breed(code: "dorking", label: "Dorking", species: .chicken),
        Breed(code: "easter_egger", label: "Easter Egger", species: .chicken),
        Breed(code: "faverolles", label: "Faverolles", species: .chicken),
        Breed(code: "hamburg", label: "Hamburg", species: .chicken),
        Breed(code: "holland", label: "Holland", species: .chicken),
        Breed(code: "houdan", label: "Houdan", species: .chicken),
        Breed(code: "java", label: "Java", species: .chicken),
        Breed(code: "jersey_giant", label: "Jersey Giant", species: .chicken),
        Breed(code: "la_fleche", label: "La Fleche", species: .chicken),
        Breed(code: "lakenvelder", label: "Lakenvelder", species: .chicken),
        Breed(code: "langshan", label: "Langshan", species: .chicken),
        Breed(code: "leghorn", label: "Leghorn", species: .chicken),
        Breed(code: "malay", label: "Malay", species: .chicken),
        Breed(code: "marans", label: "Marans", species: .chicken),
        Breed(code: "minorca", label: "Minorca", species: .chicken),
        Breed(code: "modern_game", label: "Modern Game", species: .chicken),
        Breed(code: "naked_neck", label: "Naked Neck", species: .chicken),
        Breed(code: "new_hampshire", label: "New Hampshire", species: .chicken),
        Breed(code: "old_english_game", label: "Old English Game", species: .chicken),
        Breed(code: "orpington", label: "Orpington", species: .chicken),
        Breed(code: "phoenix", label: "Phoenix", species: .chicken),
        Breed(code: "plymouth_rock", label: "Plymouth Rock", species: .chicken),
        Breed(code: "polish", label: "Polish", species: .chicken),
        Breed(code: "rhode_island_red", label: "Rhode Island Red", species: .chicken),
        Breed(code: "rhode_island_white", label: "Rhode Island White", species: .chicken),
        Breed(code: "sebright", label: "Sebright", species: .chicken),
        Breed(code: "silkie", label: "Silkie", species: .chicken),
        Breed(code: "chicken_spanish", label: "Spanish", species: .chicken),
        Breed(code: "sultan", label: "Sultan", species: .chicken),
        Breed(code: "sumatra", label: "Sumatra", species: .chicken),
        Breed(code: "sussex", label: "Sussex", species: .chicken),
        Breed(code: "welsummer", label: "Welsummer", species: .chicken),
        Breed(code: "wyandotte", label: "Wyandotte", species: .chicken),
        Breed(code: "yokohama", label: "Yokohama", species: .chicken),
        Breed(code: "berkshire", label: "Berkshire", species: .pig),
        Breed(code: "chester_white", label: "Chester White", species: .pig),
        Breed(code: "duroc", label: "Duroc", species: .pig),
        Breed(code: "pig_hampshire", label: "Hampshire", species: .pig),
        Breed(code: "landrace", label: "Landrace", species: .pig),
        Breed(code: "tamworth", label: "Tamworth", species: .pig),
        Breed(code: "yorkshire", label: "Yorkshire", species: .pig),
        Breed(code: "gloucestershire_old_spots", label: "Gloucestershire Old Spots", species: .pig),
        Breed(code: "guinea_hog", label: "Guinea Hog", species: .pig),
        Breed(code: "hereford_hog", label: "Hereford", species: .pig),
        Breed(code: "large_black", label: "Large Black", species: .pig),
        Breed(code: "mangalitsa", label: "Mangalitsa", species: .pig),
        Breed(code: "meishan", label: "Meishan", species: .pig),
        Breed(code: "mulefoot", label: "Mulefoot", species: .pig),
        Breed(code: "ossabaw", label: "Ossabaw Island", species: .pig),
        Breed(code: "red_wattle", label: "Red Wattle", species: .pig),
        Breed(code: "spotted", label: "Spotted", species: .pig),
        Breed(code: "appaloosa", label: "Appaloosa", species: .horse),
        Breed(code: "arabian", label: "Arabian", species: .horse),
        Breed(code: "belgian", label: "Belgian", species: .horse),
        Breed(code: "clydesdale", label: "Clydesdale", species: .horse),
        Breed(code: "friesian", label: "Friesian", species: .horse),
        Breed(code: "haflinger", label: "Haflinger", species: .horse),
        Breed(code: "miniature", label: "Miniature Horse", species: .horse),
        Breed(code: "morgan", label: "Morgan", species: .horse),
        Breed(code: "mustang", label: "Mustang", species: .horse),
        Breed(code: "paint", label: "Paint", species: .horse),
        Breed(code: "paso_fino", label: "Paso Fino", species: .horse),
        Breed(code: "percheron", label: "Percheron", species: .horse),
        Breed(code: "quarter_horse", label: "Quarter Horse", species: .horse),
        Breed(code: "saddlebred", label: "American Saddlebred", species: .horse),
        Breed(code: "standardbred", label: "Standardbred", species: .horse),
        Breed(code: "tennessee_walker", label: "Tennessee Walker", species: .horse),
        Breed(code: "thoroughbred", label: "Thoroughbred", species: .horse),
        Breed(code: "warmblood", label: "Warmblood", species: .horse),
        Breed(code: "andalusian", label: "Andalusian", species: .horse),
        Breed(code: "fjord", label: "Norwegian Fjord", species: .horse),
        Breed(code: "gypsy_vanner", label: "Gypsy Vanner", species: .horse),
        Breed(code: "icelandic_horse", label: "Icelandic", species: .horse),
        Breed(code: "missouri_fox_trotter", label: "Missouri Fox Trotter", species: .horse),
        Breed(code: "rocky_mountain", label: "Rocky Mountain Horse", species: .horse),
        Breed(code: "shetland_pony", label: "Shetland Pony", species: .horse),
        Breed(code: "shire", label: "Shire", species: .horse),
        Breed(code: "welsh_pony", label: "Welsh Pony", species: .horse),
    ]

    static let dogBreeds = [
        "Akita", "Australian Cattle Dog", "Australian Shepherd", "Basset Hound", "Beagle",
        "Belgian Malinois", "Bernese Mountain Dog", "Bichon Frise", "Bloodhound", "Border Collie",
        "Boston Terrier", "Boxer", "Brittany", "Bulldog", "Bull Terrier", "Cane Corso",
        "Catahoula Leopard Dog", "Cavalier King Charles Spaniel", "Chesapeake Bay Retriever",
        "Chihuahua", "Chow Chow", "Cocker Spaniel", "Collie", "Dachshund", "Dalmatian",
        "Doberman Pinscher", "English Setter", "English Springer Spaniel", "French Bulldog",
        "German Shepherd", "German Shorthaired Pointer", "Golden Retriever", "Great Dane",
        "Great Pyrenees", "Greyhound", "Havanese", "Irish Setter", "Jack Russell Terrier",
        "Labradoodle", "Labrador Retriever", "Maltese", "Mastiff", "Miniature Schnauzer",
        "Newfoundland", "Papillon", "Pembroke Welsh Corgi", "Pit Bull", "Pointer", "Pomeranian",
        "Poodle", "Pug", "Rat Terrier", "Rottweiler", "Saint Bernard", "Samoyed",
        "Shetland Sheepdog", "Shiba Inu", "Shih Tzu", "Siberian Husky", "Vizsla", "Weimaraner",
        "West Highland White Terrier", "Whippet", "Yorkshire Terrier",
        "Afghan Hound", "Airedale Terrier", "Alaskan Malamute", "American Staffordshire Terrier",
        "Basenji", "Belgian Tervuren", "Bluetick Coonhound", "Border Terrier", "Bouvier des Flandres",
        "Boykin Spaniel", "Bullmastiff", "Cairn Terrier", "Cardigan Welsh Corgi", "Chinese Crested",
        "English Cocker Spaniel", "Flat-Coated Retriever", "Giant Schnauzer", "Gordon Setter",
        "Irish Wolfhound", "Italian Greyhound", "Keeshond", "Leonberger", "Lhasa Apso",
        "Miniature Pinscher", "Norwegian Elkhound", "Nova Scotia Duck Tolling Retriever",
        "Old English Sheepdog", "Pekingese", "Portuguese Water Dog", "Redbone Coonhound",
        "Rhodesian Ridgeback", "Scottish Terrier", "Shar-Pei", "Soft Coated Wheaten Terrier",
        "Staffordshire Bull Terrier", "Standard Schnauzer", "Treeing Walker Coonhound",
        "Welsh Terrier", "Wire Fox Terrier",
    ]

    static let catBreeds = [
        "Abyssinian", "American Curl", "American Shorthair", "Balinese", "Bengal", "Birman",
        "Bombay", "British Shorthair", "Burmese", "Cornish Rex", "Devon Rex", "Domestic Longhair",
        "Domestic Shorthair", "Exotic Shorthair", "Maine Coon", "Manx", "Norwegian Forest Cat",
        "Oriental", "Persian", "Ragdoll", "Russian Blue", "Savannah", "Scottish Fold", "Siamese",
        "Siberian", "Somali", "Sphynx", "Turkish Angora",
        "American Bobtail", "Chartreux", "Egyptian Mau", "Havana Brown", "Japanese Bobtail",
        "Ocicat", "Singapura", "Snowshoe", "Tonkinese",
    ]

    static let birdBreeds = [
        "African Grey", "Amazon", "Budgerigar", "Caique", "Canary", "Cockatiel", "Cockatoo",
        "Conure", "Dove", "Eclectus", "Finch", "Gouldian Finch", "Lorikeet", "Lovebird", "Macaw",
        "Parakeet", "Pigeon", "Quaker", "Ringneck", "Senegal", "Zebra Finch",
        "Bourke's Parakeet", "Diamond Dove", "Meyer's Parrot", "Monk Parakeet", "Parrotlet",
        "Pionus", "Society Finch", "Sun Conure",
    ]

    static let reptileBreeds = [
        "Ball Python", "Bearded Dragon", "Blue Tongue Skink", "Boa", "Box Turtle", "Chameleon",
        "Corn Snake", "Crested Gecko", "Hognose", "Iguana", "King Snake", "Leopard Gecko",
        "Milk Snake", "Red-Eared Slider", "Russian Tortoise", "Sulcata", "Tortoise", "Uromastyx",
        "Veiled Chameleon", "Ackie Monitor", "Argentine Tegu", "Gargoyle Gecko", "Green Anole",
        "Leopard Tortoise", "Painted Turtle", "Panther Chameleon", "Red-Footed Tortoise",
        "Savannah Monitor",
    ]

    struct PetBreedMenuChoice: Identifiable, Equatable, Sendable {
        let value: String
        let label: String
        var id: String { value }
    }

    static func petBreeds(for kind: PetKind?) -> [String] {
        switch kind {
        case .dog: dogBreeds
        case .cat: catBreeds
        case .bird: birdBreeds
        case .reptile: reptileBreeds
        case .other, nil: []
        }
    }

    /// Mixed and a typed breed stay first so a long species list cannot hide them.
    static func petBreedMenu(for kind: PetKind?) -> [PetBreedMenuChoice] {
        var menu = [
            PetBreedMenuChoice(value: "mixed", label: "Mixed"),
            PetBreedMenuChoice(value: "typed", label: "Type a breed"),
        ]
        if let kind, kind != .other {
            menu.append(contentsOf: petBreeds(for: kind).map { PetBreedMenuChoice(value: $0, label: $0) })
        }
        return menu
    }

    static func acceptsSpeciesCode(_ code: String) -> Bool {
        durableSpeciesCodes.contains(code)
    }

    static func productionTypes(for species: Species?) -> [ProductionType] {
        guard let species else { return [] }
        let types: [ProductionType] = switch species {
        case .cattle, .dairyCow: [.dairy, .breeding]
        case .bison: [.breeding]
        case .chicken: [.layer, .broiler, .breeding]
        case .goat: [.dairy, .breeding]
        case .horse, .sheep, .pig: [.breeding, .companion]
        case .pet: [.companion]
        }
        let offered = species == .pet ? types : types + [.forSale, .personalMeat]
        return offered.sorted { $0.label < $1.label }
    }

    static func breeds(for species: Species?) -> [Breed] {
        guard let species else { return [] }
        return breeds.filter { $0.species == species }.sorted { $0.label < $1.label }
    }

    static func accepts(species: Species?, production: ProductionType?, breed: Breed?) -> Bool {
        guard let species, let production else { return false }
        let offered = productionTypes(for: species).contains(production)
        let recordedBeef = production == .beef && (species == .cattle || species == .bison || species == .goat)
        guard offered || recordedBeef else { return false }
        return breed == nil || breed?.species == species
    }

    static func productionChoices(for species: Species, including current: ProductionType) -> [ProductionType] {
        var choices = productionTypes(for: species)
        if !choices.contains(current) {
            choices.append(current)
        }
        return choices.sorted { $0.label < $1.label }
    }

    static func breedChoices(for species: Species, including current: Breed?) -> [Breed] {
        var choices = breeds(for: species)
        if let current, !choices.contains(current) {
            choices.append(current)
        }
        return choices.sorted { $0.label < $1.label }
    }
}

enum LivestockIdentifierKind: String, CaseIterable, Identifiable, Sendable {
    case earTag = "ear_tag"
    case rfid
    case brand
    case registryNumber = "registry_number"
    case license
    case other

    var id: String { rawValue }
    var label: String {
        switch self {
        case .earTag: "Ear tag"
        case .rfid: "RFID"
        case .brand: "Brand"
        case .registryNumber: "Registry number"
        case .license: "License"
        case .other: "Other"
        }
    }

    var valuePrompt: String {
        switch self {
        case .license: "License number"
        case .other: "Identifier"
        default: "Value"
        }
    }

    static func choices(for species: Species) -> [LivestockIdentifierKind] {
        species == .pet ? [.license, .other] : [.earTag, .rfid, .brand, .registryNumber]
    }

    func fits(_ species: Species) -> Bool {
        Self.choices(for: species).contains(self)
    }

    static func acceptsCode(_ code: String) -> Bool {
        allCases.contains { $0.rawValue == code }
    }
}

enum LivestockIdentifierRetirementReason: String, CaseIterable, Identifiable, Sendable {
    case rehomed, replaced, lost, invalid, duplicate, deceased, processed, sold

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    static func choices(for species: Species) -> [LivestockIdentifierRetirementReason] {
        species == .pet
            ? [.rehomed, .deceased, .lost]
            : [.deceased, .processed, .sold]
    }

    func fits(_ species: Species) -> Bool {
        Self.choices(for: species).contains(self)
    }
}

enum LivestockLifecycleEventType: String, CaseIterable, Identifiable, Sendable {
    case intake
    case tagged
    case weightRecorded = "weight_recorded"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .intake: "Intake"
        case .tagged: "Tagged"
        case .weightRecorded: "Weight recorded"
        }
    }

    static func acceptsCode(_ code: String) -> Bool {
        allCases.contains { $0.rawValue == code }
    }
}

enum LivestockLifecycleCorrectionReason: String, CaseIterable, Identifiable, Sendable {
    case incorrectTime = "incorrect_time"
    case incorrectValue = "incorrect_value"
    case duplicateEntry = "duplicate_entry"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .incorrectTime: "Incorrect time"
        case .incorrectValue: "Incorrect value"
        case .duplicateEntry: "Duplicate entry"
        }
    }

    /// A cost has no time of its own, so it can only be wrong or a duplicate.
    static let costChoices: [LivestockLifecycleCorrectionReason] = [.incorrectValue, .duplicateEntry]
}

enum LivestockCareEventType: String, CaseIterable, Identifiable, Sendable {
    case observation, treatment, surgery, vaccination
    case medicationAdministration = "medication_administration"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .observation: "Observation"
        case .treatment: "Treatment"
        case .surgery: "Surgery"
        case .vaccination: "Vaccination"
        case .medicationAdministration: "Medication"
        }
    }
    var needsConfirmation: Bool {
        switch self {
        case .surgery, .vaccination, .medicationAdministration: true
        case .observation, .treatment: false
        }
    }

    /// Observation may be recorded at average cost zero. Every other care type needs a cost.
    var requiresCost: Bool {
        switch self {
        case .observation: false
        case .treatment, .surgery, .vaccination, .medicationAdministration: true
        }
    }

    var costRequirementNote: String {
        if requiresCost {
            return "Cost is required for \(label). This does not post to Finance."
        }
        return "Average cost can be zero. This does not post to Finance."
    }

    func costProblem(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return requiresCost ? "\(label) cost is required." : nil
        }
        return LivestockMoney.requirement(text, label: "\(label) cost", allowZero: true, allowNegative: true)
    }

    /// Vaccination and medication need the amount given. Observation, treatment, and surgery do not.
    var requiresDosage: Bool {
        switch self {
        case .vaccination, .medicationAdministration: true
        case .observation, .treatment, .surgery: false
        }
    }

    var dosageRequirementNote: String {
        "Dosage is required for \(label). Record how much was given, such as 5 mL or 2 cc."
    }

    func dosageProblem(_ text: String) -> String? {
        guard requiresDosage else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "\(label) dosage is required."
        }
        if trimmed.count > 80 {
            return "\(label) dosage is too long."
        }
        return nil
    }
}

struct LivestockCareEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let type: LivestockCareEventType
    let occurredAt: Date
    var itemName: String? = nil
    var itemKind: String? = nil
    var dosage: String? = nil
    var supersedesID: UUID? = nil
    var correctionReason: LivestockLifecycleCorrectionReason? = nil
    var isCurrent: Bool = true

    var summary: String {
        var parts = [type.label]
        if let itemName, !itemName.isEmpty { parts.append(itemName) }
        if let itemKind, !itemKind.isEmpty { parts.append(itemKind) }
        if let dosage, !dosage.isEmpty { parts.append(dosage) }
        return parts.joined(separator: " · ")
    }

    /// Shown in totals and overviews: the latest correction, unless it removed a duplicate.
    var isActive: Bool { isCurrent && correctionReason != .duplicateEntry }

    var historyTitle: String {
        LivestockCorrectionTitle.title(summary, reason: correctionReason, isCurrent: isCurrent)
    }
}

enum LivestockCorrectionTitle {
    static func title(_ base: String, reason: LivestockLifecycleCorrectionReason?, isCurrent: Bool) -> String {
        var title = base
        if reason == .duplicateEntry {
            title += " · removed as a duplicate"
        } else if let reason {
            title += " · \(reason.label)"
        }
        if !isCurrent {
            title += " · earlier record"
        }
        return title
    }

    /// Ids of a record and every earlier record it corrected.
    static func chain(from id: UUID, supersedes: [UUID: UUID]) -> Set<UUID> {
        var ids: Set<UUID> = [id]
        var cursor = id
        while let earlier = supersedes[cursor], ids.insert(earlier).inserted {
            cursor = earlier
        }
        return ids
    }
}

enum LivestockInputType: String, CaseIterable, Identifiable, Codable, Sendable {
    case feed, hay, mineral, supplement
    case dryFood = "dry_food"
    case wetFood = "wet_food"
    case pasture
    case grassHay = "grass_hay"
    case alfalfaHay = "alfalfa_hay"
    case corn
    case cornSilage = "corn_silage"
    case oats
    case preparedMeal = "prepared_meal"
    case browse, scratch
    case oysterShell = "oyster_shell"
    case grit, seed, pellets, insects, greens

    var id: String { rawValue }
    var label: String {
        switch self {
        case .feed: "Feed"
        case .hay: "Hay"
        case .mineral: "Mineral"
        case .supplement: "Supplement"
        case .dryFood: "Dry food"
        case .wetFood: "Wet food"
        case .pasture: "Pasture"
        case .grassHay: "Grass hay"
        case .alfalfaHay: "Alfalfa hay"
        case .corn: "Corn"
        case .cornSilage: "Corn silage"
        case .oats: "Oats"
        case .preparedMeal: "Prepared meal"
        case .browse: "Browse"
        case .scratch: "Scratch"
        case .oysterShell: "Oyster shell"
        case .grit: "Grit"
        case .seed: "Seed"
        case .pellets: "Pellets"
        case .insects: "Insects"
        case .greens: "Greens"
        }
    }

    /// Usual rations for the species. Cattle, bison, sheep, goats, and horses are offered pasture and hay; pigs and chickens a prepared meal; pets the food for that kind of pet.
    static func entryChoices(for species: Species, petKind: PetKind? = nil) -> [LivestockInputType] {
        switch species {
        case .cattle, .dairyCow, .bison:
            return [.pasture, .grassHay, .alfalfaHay, .corn, .cornSilage, .preparedMeal, .mineral, .supplement]
        case .horse:
            return [.pasture, .grassHay, .alfalfaHay, .oats, .preparedMeal, .mineral, .supplement]
        case .goat:
            return [.pasture, .browse, .grassHay, .alfalfaHay, .corn, .preparedMeal, .mineral, .supplement]
        case .sheep:
            return [.pasture, .grassHay, .alfalfaHay, .corn, .preparedMeal, .mineral, .supplement]
        case .pig:
            return [.preparedMeal, .corn, .pasture, .supplement]
        case .chicken:
            return [.preparedMeal, .scratch, .corn, .oysterShell, .grit, .supplement]
        case .pet:
            switch petKind {
            case .bird:
                return [.seed, .pellets, .preparedMeal, .supplement]
            case .reptile:
                return [.insects, .greens, .preparedMeal, .supplement]
            case .dog, .cat, .other, nil:
                return [.dryFood, .wetFood, .preparedMeal, .supplement]
            }
        }
    }

    /// Mixed-herd rations. The record belongs to the herd, not copied onto each animal.
    static var herdChoices: [LivestockInputType] {
        [.hay, .grassHay, .alfalfaHay, .feed, .pasture, .preparedMeal, .mineral, .supplement, .corn, .cornSilage, .oats]
    }
}

struct LivestockFeedEntry: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var inputType: LivestockInputType
    var quantity: String = ""
    var unit: LivestockInputUnit = .lb
    var frequency: LivestockCostFrequency = .daily
    var cost: String = ""
    var financeReference: String = ""

    var hasQuantity: Bool {
        !quantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Every feed record carries a whole quantity of 1 or more and a cost greater than zero.
    static func problem(quantity: String, cost: String, feed: String) -> String? {
        guard let count = Int(quantity.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else {
            return "\(feed) needs a quantity of 1 or more."
        }
        return LivestockMoney.requirement(cost, label: "\(feed) cost", allowZero: false)
    }

    static func canSave(_ lines: [LivestockFeedEntry]) -> Bool {
        let filled = lines.filter {
            $0.hasQuantity || !$0.cost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !filled.isEmpty else { return false }
        return filled.allSatisfy { problem(quantity: $0.quantity, cost: $0.cost, feed: $0.inputType.label) == nil }
    }

    /// Quantity times the cost of one feeding times how often that feeding happens in a year.
    var annualFeedCost: Decimal {
        guard let count = Int(quantity.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else {
            return 0
        }
        return Decimal(count) * LivestockMoney.signed(cost) * Decimal(frequency.timesPerYear)
    }
}

struct LivestockFeedSubtotal: Identifiable, Equatable, Sendable {
    let inputType: LivestockInputType
    let frequency: LivestockCostFrequency
    let amount: Decimal

    var id: String { "\(inputType.rawValue)-\(frequency.rawValue)" }
    var label: String { "\(inputType.label) · \(frequency.label)" }
}

struct LivestockCostSummary: Equatable, Sendable {
    var feedSubtotals: [LivestockFeedSubtotal]
    var feedTotal: Decimal
    var other: Decimal
    var total: Decimal
}

enum LivestockInputUnit: String, CaseIterable, Identifiable, Sendable {
    case lb, kg, bale, bag, scoop, cup, each

    var id: String { rawValue }
    var label: String {
        switch self {
        case .lb: "Pounds"
        case .kg: "Kilograms"
        case .bale: "Bale"
        case .bag: "Bag"
        case .scoop: "Scoop"
        case .cup: "Cup"
        case .each: "Each"
        }
    }

    static let entryChoices: [LivestockInputUnit] = [.scoop, .cup, .bale, .each, .bag, .lb]
}

enum LivestockCostFrequency: String, CaseIterable, Identifiable, Sendable {
    case daily, weekly, monthly, quarterly
    case semiAnnual = "semi_annual"
    case annual

    var id: String { rawValue }
    var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .semiAnnual: "Semi-annual"
        case .annual: "Annual"
        }
    }

    /// How many of these feedings fall in one year.
    var timesPerYear: Int {
        switch self {
        case .daily: 365
        case .weekly: 52
        case .monthly: 12
        case .quarterly: 4
        case .semiAnnual: 2
        case .annual: 1
        }
    }
}

struct LivestockConsumption: Identifiable, Equatable, Sendable {
    let id: UUID
    let inputType: LivestockInputType
    let quantity: String
    let unit: LivestockInputUnit
    let observedAt: Date
    let supplier: String?
    let batch: String?
    var frequency: LivestockCostFrequency? = nil
    var supersedesID: UUID? = nil
    var correctionReason: LivestockLifecycleCorrectionReason? = nil
    var isCurrent: Bool = true

    var summary: String {
        var parts = ["\(inputType.label) \(quantity) \(unit.label)"]
        if let frequency {
            parts.append(frequency.label)
        }
        let named = LivestockSupplierDirectory.cleaned(supplier ?? "")
        if !named.isEmpty {
            parts.append(named)
        }
        return parts.joined(separator: " · ")
    }

    var isActive: Bool { isCurrent && correctionReason != .duplicateEntry }

    var historyTitle: String {
        LivestockCorrectionTitle.title(summary, reason: correctionReason, isCurrent: isCurrent)
    }
}

struct LivestockSupplierDirectory: Equatable, Codable, Sendable {
    var names: [String] = []
    var last: String = ""

    static func cleaned(_ raw: String) -> String {
        String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
    }

    mutating func remember(_ raw: String) {
        let name = Self.cleaned(raw)
        guard !name.isEmpty else { return }
        names.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        names.append(name)
        names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        last = name
    }

    func merging(animals: [Animal], herds: [LivestockHerd] = []) -> LivestockSupplierDirectory {
        var copy = self
        let recorded = Self.recordedNames(
            from: animals.flatMap(\.consumptions) + herds.flatMap(\.consumptions)
        )
        let keptLast = copy.last
        for name in recorded {
            copy.remember(name)
        }
        if !keptLast.isEmpty {
            copy.last = Self.cleaned(keptLast)
        }
        return copy
    }

    private static func recordedNames(from items: [LivestockConsumption]) -> [String] {
        items.compactMap { item -> (Date, String)? in
            guard let supplier = item.supplier else { return nil }
            let name = cleaned(supplier)
            guard !name.isEmpty else { return nil }
            return (item.observedAt, name)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    static func load(defaults: UserDefaults = .standard) -> LivestockSupplierDirectory {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(LivestockSupplierDirectory.self, from: data) else {
            return LivestockSupplierDirectory()
        }
        return stored
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static let storageKey = "RanchOSLivestock.feedSuppliers"
}

enum LivestockProductCategory: String, Codable, CaseIterable, Sendable {
    case feed
    case vaccination
    case medication

    var pickerTitle: String {
        switch self {
        case .feed: "Scanned feed"
        case .vaccination: "Shots"
        case .medication: "Medicines"
        }
    }

    var emptyPickerLabel: String {
        switch self {
        case .feed: "Choose a scanned feed"
        case .vaccination: "Choose a shot"
        case .medication: "Choose a medicine"
        }
    }

    var scanLabel: String {
        switch self {
        case .feed: "Scan feed package"
        case .vaccination: "Scan shot package"
        case .medication: "Scan medicine package"
        }
    }
}

struct LivestockProduct: Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    var category: LivestockProductCategory
    var name: String
    var kind: String = ""
    var barcode: String? = nil
    var feedType: LivestockInputType? = nil
}

struct LivestockProductDirectory: Equatable, Codable, Sendable {
    var products: [LivestockProduct] = []

    static func cleanedName(_ raw: String) -> String {
        String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
    }

    static func cleanedBarcode(_ raw: String) -> String {
        let allowed = raw.uppercased().filter { $0.isNumber || ("A"..."Z").contains($0) }
        return String(allowed.prefix(32))
    }

    func products(in category: LivestockProductCategory) -> [LivestockProduct] {
        products.filter { $0.category == category }
    }

    func product(barcode: String, in category: LivestockProductCategory) -> LivestockProduct? {
        let code = Self.cleanedBarcode(barcode)
        guard !code.isEmpty else { return nil }
        return products.first { $0.category == category && $0.barcode == code }
    }

    mutating func remember(_ incoming: LivestockProduct) {
        let name = Self.cleanedName(incoming.name)
        guard !name.isEmpty else { return }
        let barcode = Self.cleanedBarcode(incoming.barcode ?? "")
        let kind = Self.cleanedName(incoming.kind)
        if let index = products.firstIndex(where: { product in
            if !barcode.isEmpty, product.category == incoming.category, product.barcode == barcode {
                return true
            }
            return product.category == incoming.category && product.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            products[index].name = name
            if !kind.isEmpty { products[index].kind = kind }
            if !barcode.isEmpty { products[index].barcode = barcode }
            if incoming.feedType != nil { products[index].feedType = incoming.feedType }
        } else {
            products.append(
                LivestockProduct(
                    category: incoming.category,
                    name: name,
                    kind: kind,
                    barcode: barcode.isEmpty ? nil : barcode,
                    feedType: incoming.feedType
                )
            )
        }
        products.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func merging(animals: [Animal], herds: [LivestockHerd] = []) -> LivestockProductDirectory {
        var copy = self
        let events = animals.flatMap(\.careEvents) + herds.flatMap(\.careEvents)
        for event in events where event.isActive {
            let name = Self.cleanedName(event.itemName ?? "")
            guard !name.isEmpty else { continue }
            switch event.type {
            case .vaccination:
                copy.remember(LivestockProduct(category: .vaccination, name: name))
            case .medicationAdministration:
                copy.remember(
                    LivestockProduct(
                        category: .medication,
                        name: name,
                        kind: Self.cleanedName(event.itemKind ?? "")
                    )
                )
            case .observation, .treatment, .surgery:
                continue
            }
        }
        return copy
    }

    static func load(defaults: UserDefaults = .standard) -> LivestockProductDirectory {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(LivestockProductDirectory.self, from: data) else {
            return LivestockProductDirectory()
        }
        return stored
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static let storageKey = "RanchOSLivestock.scannedProducts"
}

enum LivestockWeight {
    static func decimal(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func requirement(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty else { return "Enter the weight in pounds." }
        guard let value = decimal(trimmed), value > 0 else {
            return "Weight must be a number of pounds greater than zero."
        }
        if let dot = trimmed.firstIndex(of: "."), trimmed.distance(from: trimmed.index(after: dot), to: trimmed.endIndex) > 2 {
            return "Weight must be a number of pounds greater than zero."
        }
        return nil
    }

    static func pounds(_ value: Decimal) -> String {
        "\(shown(value, maximumFractionDigits: 2)) lb"
    }

    /// International avoirdupois pound. Display rounds to the nearest hundredth of a kilogram.
    static func kilogramsText(for text: String) -> String {
        guard requirement(text) == nil, let pounds = decimal(text) else { return "—" }
        var kilograms = pounds * Decimal(string: "0.45359237")!
        var rounded = Decimal()
        NSDecimalRound(&rounded, &kilograms, 2, .plain)
        return "\(shown(rounded, maximumFractionDigits: 2)) kg"
    }

    private static func shown(_ value: Decimal, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
}

enum LivestockMoney {
    /// Up to the ten-thousands of dollars and two cent digits. A leading minus is kept for a correction.
    static func entry(_ raw: String) -> String {
        let negative = raw.contains("-")
        var dollars = ""
        var cents: String?
        for character in raw {
            if character.isNumber {
                if let partial = cents {
                    if partial.count < 2 { cents = partial + String(character) }
                } else if dollars.count < 5 {
                    dollars.append(character)
                }
            } else if character == ".", cents == nil {
                cents = ""
            }
        }
        var result = dollars
        if let cents { result += "." + cents }
        if result.isEmpty { return negative ? "-" : "" }
        return negative ? "-" + result : result
    }

    static func decimal(_ text: String) -> Decimal? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func requirement(_ text: String, label: String, allowZero: Bool = true, allowNegative: Bool = false) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return allowZero ? "\(label) is required. Zero is allowed." : "\(label) is required."
        }
        guard let value = decimal(trimmed) else { return "\(label) must be a number." }
        if value < 0, !allowNegative { return "\(label) cannot be negative." }
        if !allowZero, value == 0 {
            return allowNegative ? "\(label) must be a number other than zero." : "\(label) must be greater than zero."
        }
        return nil
    }

    static func nonNegative(_ text: String) -> Decimal {
        guard let value = decimal(text), value >= 0 else { return 0 }
        return value
    }

    static func signed(_ text: String) -> Decimal {
        decimal(text) ?? 0
    }

    static func plain(_ value: Decimal) -> String? {
        guard value != 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSDecimalNumber(decimal: value))
    }

    static func nonzeroText(_ text: String) -> String? {
        guard let value = decimal(text), value != 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSDecimalNumber(decimal: value))
    }

    static func amountText(_ text: String) -> String? {
        guard let value = decimal(text), value >= 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSDecimalNumber(decimal: value))
    }

    static func positiveText(_ text: String) -> String? {
        guard let value = decimal(text), value > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSDecimalNumber(decimal: value))
    }

    static func total(recorded: Decimal, entered: Decimal) -> Decimal {
        let sum = recorded + entered
        return sum < 0 ? 0 : sum
    }

    static func usd(_ value: Decimal) -> String {
        let amount = value < 0 ? 0 : value
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "$0.00"
    }

    static func usdSigned(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "$0.00"
    }
}

struct LivestockCostBuckets: Equatable, Sendable {
    var daily: Decimal = 0
    var weekly: Decimal = 0
    var monthly: Decimal = 0
    var quarterly: Decimal = 0
    var semiAnnual: Decimal = 0
    var annual: Decimal = 0
    var other: Decimal = 0

    var total: Decimal {
        let sum = daily + weekly + monthly + quarterly + semiAnnual + annual + other
        return sum < 0 ? 0 : sum
    }

    func adding(_ amount: Decimal, frequency: LivestockCostFrequency?) -> LivestockCostBuckets {
        var copy = self
        switch frequency {
        case .daily: copy.daily += amount
        case .weekly: copy.weekly += amount
        case .monthly: copy.monthly += amount
        case .quarterly: copy.quarterly += amount
        case .semiAnnual: copy.semiAnnual += amount
        case .annual: copy.annual += amount
        case nil: copy.other += amount
        }
        return copy
    }

    func combined(with recorded: LivestockCostBuckets) -> LivestockCostBuckets {
        LivestockCostBuckets(
            daily: daily + recorded.daily,
            weekly: weekly + recorded.weekly,
            monthly: monthly + recorded.monthly,
            quarterly: quarterly + recorded.quarterly,
            semiAnnual: semiAnnual + recorded.semiAnnual,
            annual: annual + recorded.annual,
            other: other + recorded.other
        )
    }
}

struct LivestockCostAttribution: Identifiable, Equatable, Sendable {
    let id: UUID
    let amount: String
    let financeReference: String?
    let recordedAt: Date
    var frequency: LivestockCostFrequency? = nil
    var feedType: LivestockInputType? = nil
    var lifecycleEventID: UUID? = nil
    var careEventID: UUID? = nil
    var consumptionID: UUID? = nil
    var supersedesID: UUID? = nil
    var correctionReason: LivestockLifecycleCorrectionReason? = nil
    var isCurrent: Bool = true

    var isEventCost: Bool { lifecycleEventID != nil || careEventID != nil }

    var linkedRecordID: UUID? { lifecycleEventID ?? careEventID ?? consumptionID }

    /// Counted in totals: the latest correction, unless it removed a duplicate.
    var isCounted: Bool { isCurrent && correctionReason != .duplicateEntry }

    var basisCode: String = "per_animal"

    var summary: String {
        let unit = basisCode == "per_herd" ? "per herd" : "per animal"
        let money = "\(LivestockMoney.usd(LivestockMoney.nonNegative(amount))) \(unit)"
        if let financeReference, !financeReference.isEmpty {
            return "\(money) · Finance \(financeReference)"
        }
        return "\(money) · No Finance record is linked"
    }

    var ledgerLabel: String {
        if let feedType, let frequency {
            return "\(feedType.label) · \(frequency.label)"
        }
        if let frequency {
            return frequency.label
        }
        if lifecycleEventID != nil {
            return "Routine lifecycle"
        }
        if careEventID != nil {
            return "Care"
        }
        if let financeReference, !financeReference.isEmpty {
            return "Operational · Finance \(financeReference)"
        }
        return "Operational"
    }
}

struct LivestockTypeCost: Identifiable, Equatable, Sendable {
    let label: String
    let amount: Decimal

    var id: String { label }
}

struct LivestockDatedCost: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    let amount: Decimal
    let recordedAt: Date
}

struct LivestockCostDay: Identifiable, Equatable, Sendable {
    let day: Date
    let lines: [LivestockDatedCost]
    let total: Decimal

    var id: Date { day }
}

enum LivestockCostLedger {
    static func days(
        from costs: [LivestockCostAttribution],
        label: (LivestockCostAttribution) -> String = \.ledgerLabel,
        calendar: Calendar = .current
    ) -> [LivestockCostDay] {
        let grouped = Dictionary(grouping: costs) { calendar.startOfDay(for: $0.recordedAt) }
        return grouped.keys.sorted(by: >).map { day in
            let lines = (grouped[day] ?? []).sorted { lhs, rhs in
                if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
                return lhs.id.uuidString > rhs.id.uuidString
            }.map { cost in
                LivestockDatedCost(
                    id: cost.id,
                    label: label(cost),
                    amount: LivestockMoney.signed(cost.amount),
                    recordedAt: cost.recordedAt
                )
            }
            let sum = lines.reduce(Decimal(0)) { $0 + $1.amount }
            return LivestockCostDay(day: day, lines: lines, total: sum < 0 ? 0 : sum)
        }
    }
}

struct LivestockLifecycleEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let type: LivestockLifecycleEventType
    let occurredAt: Date
    var weightPounds: Decimal? = nil
    var supersedesEventID: UUID? = nil
    var correctionReason: LivestockLifecycleCorrectionReason? = nil
    var isCurrent: Bool = true

    var summary: String { type.label }

    var historyTitle: String {
        var title = type.label
        if type == .weightRecorded, let weightPounds {
            title += " · \(LivestockWeight.pounds(weightPounds))"
        }
        if let correctionReason {
            title += " · \(correctionReason.label)"
        }
        if !isCurrent {
            title += " · earlier record"
        }
        return title
    }
}

struct LivestockAnimalIdentifier: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: LivestockIdentifierKind
    let value: String
    var retirementReason: LivestockIdentifierRetirementReason? = nil
    var retiredAt: Date? = nil

    var isActive: Bool { retirementReason == nil }
    var summary: String { "\(kind.label) \(value)" }
}

enum LivestockAnimalSearch {
    /// Empty query keeps the full list. A query matches display name or an identifier value.
    static func listed(_ animals: [Animal], query: String) -> [Animal] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return animals }
        return animals.filter { matches($0, query: needle) }
    }

    static func matches(_ animal: Animal, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if animal.displayName.localizedStandardContains(needle) { return true }
        return animal.identifiers.contains { $0.value.localizedStandardContains(needle) }
    }
}

struct Animal: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let species: Species
    let productionType: ProductionType
    let breed: Breed?
    let identifiers: [LivestockAnimalIdentifier]
    let lifecycleEvents: [LivestockLifecycleEvent]
    let careEvents: [LivestockCareEvent]
    let consumptions: [LivestockConsumption]
    let costs: [LivestockCostAttribution]
    let recordedBreed: String?
    let mixBreedOne: String?
    let mixBreedTwo: String?
    let petKind: PetKind?
    let petSpeciesOther: String?
    let herdID: UUID?
    let herdName: String?
    let herdStartedAt: Date?
    let retirementReason: LivestockIdentifierRetirementReason?
    let retiredAt: Date?
    let saleAmount: Decimal?
    let saleOn: Date?
    let sireID: UUID?
    let damID: UUID?
    let bredWithID: UUID?
    let status: String

    init(
        id: UUID,
        displayName: String,
        species: Species,
        productionType: ProductionType,
        breed: Breed?,
        identifiers: [LivestockAnimalIdentifier],
        lifecycleEvents: [LivestockLifecycleEvent] = [],
        careEvents: [LivestockCareEvent] = [],
        consumptions: [LivestockConsumption] = [],
        costs: [LivestockCostAttribution] = [],
        recordedBreed: String? = nil,
        mixBreedOne: String? = nil,
        mixBreedTwo: String? = nil,
        petKind: PetKind? = nil,
        petSpeciesOther: String? = nil,
        herdID: UUID? = nil,
        herdName: String? = nil,
        herdStartedAt: Date? = nil,
        retirementReason: LivestockIdentifierRetirementReason? = nil,
        retiredAt: Date? = nil,
        saleAmount: Decimal? = nil,
        saleOn: Date? = nil,
        sireID: UUID? = nil,
        damID: UUID? = nil,
        bredWithID: UUID? = nil,
        status: String
    ) {
        self.id = id
        self.displayName = displayName
        self.species = species
        self.productionType = productionType
        self.breed = breed
        self.identifiers = identifiers
        self.lifecycleEvents = lifecycleEvents
        self.careEvents = careEvents
        self.consumptions = consumptions
        self.costs = costs
        self.recordedBreed = recordedBreed
        self.mixBreedOne = mixBreedOne
        self.mixBreedTwo = mixBreedTwo
        self.petKind = petKind
        self.petSpeciesOther = petSpeciesOther
        self.herdID = herdID
        self.herdName = herdName
        self.herdStartedAt = herdStartedAt
        self.retirementReason = retirementReason
        self.retiredAt = retiredAt
        self.saleAmount = saleAmount
        self.saleOn = saleOn
        self.sireID = sireID
        self.damID = damID
        self.bredWithID = bredWithID
        self.status = status
    }

    var speciesDisplay: String {
        guard species == .pet else { return species.label }
        switch petKind {
        case .dog, .cat, .bird, .reptile:
            return petKind?.label ?? "Pet"
        case .other:
            let typed = petSpeciesOther?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return typed.isEmpty ? "Other" : typed
        case nil:
            return "Pet"
        }
    }

    var breedDisplay: String {
        if let mixBreedOne, let mixBreedTwo,
           !mixBreedOne.isEmpty, !mixBreedTwo.isEmpty {
            return "\(mixBreedOne) × \(mixBreedTwo)"
        }
        if recordedBreed == "mixed" {
            return "Mixed"
        }
        if let recordedBreed, !recordedBreed.isEmpty {
            return recordedBreed
        }
        return breed?.label ?? "None selected"
    }

    var isRetired: Bool {
        retirementReason != nil || identifiers.contains { $0.retirementReason != nil }
    }

    /// Currently active until Retire records a reason. Pets and livestock use different reasons.
    var retirementDisplay: String {
        if let retirementReason { return retirementReason.label }
        guard isRetired else { return "Currently active" }
        var labels: [String] = []
        for identifier in identifiers {
            guard let reason = identifier.retirementReason else { continue }
            let label = reason.label
            if !labels.contains(label) { labels.append(label) }
        }
        return labels.isEmpty ? "Retired" : labels.joined(separator: ", ")
    }

    var retiredOn: Date? {
        ([retiredAt] + identifiers.map(\.retiredAt)).compactMap { $0 }.max()
    }

    var identifierSummary: String {
        if identifiers.isEmpty { return "No identifier" }
        let active = identifiers.filter(\.isActive)
        let shown = active.isEmpty ? identifiers : active
        return shown.map(\.summary).joined(separator: ", ")
    }

    func retiring(reason: LivestockIdentifierRetirementReason, at date: Date, saleAmount: Decimal? = nil, saleOn: Date? = nil) -> Animal {
        Animal(
            id: id,
            displayName: displayName,
            species: species,
            productionType: productionType,
            breed: breed,
            identifiers: identifiers,
            lifecycleEvents: lifecycleEvents,
            careEvents: careEvents,
            consumptions: consumptions,
            costs: costs,
            recordedBreed: recordedBreed,
            mixBreedOne: mixBreedOne,
            mixBreedTwo: mixBreedTwo,
            petKind: petKind,
            petSpeciesOther: petSpeciesOther,
            herdID: herdID,
            herdName: herdName,
            herdStartedAt: herdStartedAt,
            retirementReason: reason,
            retiredAt: date,
            saleAmount: saleAmount,
            saleOn: saleOn,
            sireID: sireID,
            damID: damID,
            bredWithID: bredWithID,
            status: status
        )
    }

    func renaming(displayName: String) -> Animal {
        Animal(
            id: id,
            displayName: displayName,
            species: species,
            productionType: productionType,
            breed: breed,
            identifiers: identifiers,
            lifecycleEvents: lifecycleEvents,
            careEvents: careEvents,
            consumptions: consumptions,
            costs: costs,
            recordedBreed: recordedBreed,
            mixBreedOne: mixBreedOne,
            mixBreedTwo: mixBreedTwo,
            petKind: petKind,
            petSpeciesOther: petSpeciesOther,
            herdID: herdID,
            herdName: herdName,
            herdStartedAt: herdStartedAt,
            retirementReason: retirementReason,
            retiredAt: retiredAt,
            saleAmount: saleAmount,
            saleOn: saleOn,
            sireID: sireID,
            damID: damID,
            bredWithID: bredWithID,
            status: status
        )
    }

    func renamingHerd(_ name: String) -> Animal {
        Animal(
            id: id,
            displayName: displayName,
            species: species,
            productionType: productionType,
            breed: breed,
            identifiers: identifiers,
            lifecycleEvents: lifecycleEvents,
            careEvents: careEvents,
            consumptions: consumptions,
            costs: costs,
            recordedBreed: recordedBreed,
            mixBreedOne: mixBreedOne,
            mixBreedTwo: mixBreedTwo,
            petKind: petKind,
            petSpeciesOther: petSpeciesOther,
            herdID: herdID,
            herdName: name,
            herdStartedAt: herdStartedAt,
            retirementReason: retirementReason,
            retiredAt: retiredAt,
            saleAmount: saleAmount,
            saleOn: saleOn,
            sireID: sireID,
            damID: damID,
            bredWithID: bredWithID,
            status: status
        )
    }

    func assigningHerd(id: UUID, name: String, at date: Date) -> Animal {
        Animal(
            id: self.id,
            displayName: displayName,
            species: species,
            productionType: productionType,
            breed: breed,
            identifiers: identifiers,
            lifecycleEvents: lifecycleEvents,
            careEvents: careEvents,
            consumptions: consumptions,
            costs: costs,
            recordedBreed: recordedBreed,
            mixBreedOne: mixBreedOne,
            mixBreedTwo: mixBreedTwo,
            petKind: petKind,
            petSpeciesOther: petSpeciesOther,
            herdID: id,
            herdName: name,
            herdStartedAt: date,
            retirementReason: retirementReason,
            retiredAt: retiredAt,
            saleAmount: saleAmount,
            saleOn: saleOn,
            sireID: sireID,
            damID: damID,
            bredWithID: bredWithID,
            status: status
        )
    }

    func clearingHerd() -> Animal {
        Animal(
            id: self.id,
            displayName: displayName,
            species: species,
            productionType: productionType,
            breed: breed,
            identifiers: identifiers,
            lifecycleEvents: lifecycleEvents,
            careEvents: careEvents,
            consumptions: consumptions,
            costs: costs,
            recordedBreed: recordedBreed,
            mixBreedOne: mixBreedOne,
            mixBreedTwo: mixBreedTwo,
            petKind: petKind,
            petSpeciesOther: petSpeciesOther,
            herdID: nil,
            herdName: nil,
            herdStartedAt: nil,
            retirementReason: retirementReason,
            retiredAt: retiredAt,
            saleAmount: saleAmount,
            saleOn: saleOn,
            sireID: sireID,
            damID: damID,
            bredWithID: bredWithID,
            status: status
        )
    }

    func replacingBreeding(sireID: UUID?, damID: UUID?, bredWithID: UUID?) -> Animal {
        Animal(
            id: id,
            displayName: displayName,
            species: species,
            productionType: productionType,
            breed: breed,
            identifiers: identifiers,
            lifecycleEvents: lifecycleEvents,
            careEvents: careEvents,
            consumptions: consumptions,
            costs: costs,
            recordedBreed: recordedBreed,
            mixBreedOne: mixBreedOne,
            mixBreedTwo: mixBreedTwo,
            petKind: petKind,
            petSpeciesOther: petSpeciesOther,
            herdID: herdID,
            herdName: herdName,
            herdStartedAt: herdStartedAt,
            retirementReason: retirementReason,
            retiredAt: retiredAt,
            saleAmount: saleAmount,
            saleOn: saleOn,
            sireID: sireID,
            damID: damID,
            bredWithID: bredWithID,
            status: status
        )
    }

    func replacingClassification(productionType: ProductionType, breed: Breed?) -> Animal {
        Animal(
            id: id,
            displayName: displayName,
            species: species,
            productionType: productionType,
            breed: breed,
            identifiers: identifiers,
            lifecycleEvents: lifecycleEvents,
            careEvents: careEvents,
            consumptions: consumptions,
            costs: costs,
            recordedBreed: recordedBreed,
            mixBreedOne: mixBreedOne,
            mixBreedTwo: mixBreedTwo,
            petKind: petKind,
            petSpeciesOther: petSpeciesOther,
            herdID: herdID,
            herdName: herdName,
            herdStartedAt: herdStartedAt,
            retirementReason: retirementReason,
            retiredAt: retiredAt,
            saleAmount: saleAmount,
            saleOn: saleOn,
            sireID: sireID,
            damID: damID,
            bredWithID: bredWithID,
            status: status
        )
    }

    func replacingIdentifiers(_ identifiers: [LivestockAnimalIdentifier]) -> Animal {
        Animal(
            id: id,
            displayName: displayName,
            species: species,
            productionType: productionType,
            breed: breed,
            identifiers: identifiers,
            lifecycleEvents: lifecycleEvents,
            careEvents: careEvents,
            consumptions: consumptions,
            costs: costs,
            recordedBreed: recordedBreed,
            mixBreedOne: mixBreedOne,
            mixBreedTwo: mixBreedTwo,
            petKind: petKind,
            petSpeciesOther: petSpeciesOther,
            herdID: herdID,
            herdName: herdName,
            herdStartedAt: herdStartedAt,
            retirementReason: retirementReason,
            retiredAt: retiredAt,
            saleAmount: saleAmount,
            saleOn: saleOn,
            sireID: sireID,
            damID: damID,
            bredWithID: bredWithID,
            status: status
        )
    }

    func replacingLifecycleEvents(_ lifecycleEvents: [LivestockLifecycleEvent]) -> Animal {
        Animal(
            id: id,
            displayName: displayName,
            species: species,
            productionType: productionType,
            breed: breed,
            identifiers: identifiers,
            lifecycleEvents: lifecycleEvents,
            careEvents: careEvents,
            consumptions: consumptions,
            costs: costs,
            recordedBreed: recordedBreed,
            mixBreedOne: mixBreedOne,
            mixBreedTwo: mixBreedTwo,
            petKind: petKind,
            petSpeciesOther: petSpeciesOther,
            herdID: herdID,
            herdName: herdName,
            herdStartedAt: herdStartedAt,
            retirementReason: retirementReason,
            retiredAt: retiredAt,
            saleAmount: saleAmount,
            saleOn: saleOn,
            sireID: sireID,
            damID: damID,
            bredWithID: bredWithID,
            status: status
        )
    }

    var recordedCostTotal: Decimal { recordedBuckets.total }

    var recordedBuckets: LivestockCostBuckets {
        activeCosts.reduce(into: LivestockCostBuckets()) { buckets, item in
            buckets = buckets.adding(LivestockMoney.signed(item.amount), frequency: item.frequency)
        }
    }

    var activeCosts: [LivestockCostAttribution] {
        let removed = removedRecordIDs
        return costs.filter { $0.isCounted && !Self.links($0, to: removed) }
    }

    /// A counted cost whose lifecycle, care, or feed record was removed as a duplicate.
    func isRemovedWithEvent(_ cost: LivestockCostAttribution) -> Bool {
        cost.isCounted && Self.links(cost, to: removedRecordIDs)
    }

    /// Counted costs saved with one lifecycle, care, or feed record or with the earlier records it corrected.
    func eventCosts(_ recordID: UUID) -> [LivestockCostAttribution] {
        let ids = LivestockCorrectionTitle.chain(from: recordID, supersedes: recordSupersedes)
        return activeCosts.filter { Self.links($0, to: ids) }
    }

    /// Signed sum of `eventCosts`; nil when none were saved.
    func eventCost(_ recordID: UUID) -> Decimal? {
        let linked = eventCosts(recordID)
        guard !linked.isEmpty else { return nil }
        return linked.reduce(Decimal(0)) { $0 + LivestockMoney.signed($1.amount) }
    }

    private var recordSupersedes: [UUID: UUID] {
        var supersedes: [UUID: UUID] = [:]
        for event in lifecycleEvents { supersedes[event.id] = event.supersedesEventID }
        for event in careEvents { supersedes[event.id] = event.supersedesID }
        for item in consumptions { supersedes[item.id] = item.supersedesID }
        return supersedes
    }

    private var removedRecordIDs: Set<UUID> {
        let supersedes = recordSupersedes
        let duplicates = lifecycleEvents.filter { $0.isCurrent && $0.correctionReason == .duplicateEntry }.map(\.id)
            + careEvents.filter { $0.isCurrent && $0.correctionReason == .duplicateEntry }.map(\.id)
            + consumptions.filter { $0.isCurrent && $0.correctionReason == .duplicateEntry }.map(\.id)
        return duplicates.reduce(into: Set<UUID>()) { removed, id in
            removed.formUnion(LivestockCorrectionTitle.chain(from: id, supersedes: supersedes))
        }
    }

    private static func links(_ cost: LivestockCostAttribution, to ids: Set<UUID>) -> Bool {
        cost.linkedRecordID.map(ids.contains) ?? false
    }

    var lifecycleCostByType: [LivestockTypeCost] {
        LivestockLifecycleEventType.allCases.compactMap { type in
            let ids = Set(lifecycleEvents.filter { $0.type == type }.map(\.id))
            return Self.typeCost(type.label, activeCosts.filter { $0.lifecycleEventID.map(ids.contains) == true })
        }
    }

    var careCostByType: [LivestockTypeCost] {
        LivestockCareEventType.allCases.compactMap { type in
            let ids = Set(careEvents.filter { $0.type == type }.map(\.id))
            return Self.typeCost(type.label, activeCosts.filter { $0.careEventID.map(ids.contains) == true })
        }
    }

    /// Feed costs saved with a feed record; older feed costs without a record count only in the ledger.
    var feedCostByType: [LivestockTypeCost] {
        LivestockInputType.allCases.compactMap { type in
            Self.typeCost(type.label, activeCosts.filter { $0.consumptionID != nil && $0.feedType == type })
        }
    }

    func costLabel(_ cost: LivestockCostAttribution) -> String {
        if let id = cost.lifecycleEventID, let event = lifecycleEvents.first(where: { $0.id == id }) {
            return "Routine lifecycle · \(event.type.label)"
        }
        if let id = cost.careEventID, let event = careEvents.first(where: { $0.id == id }) {
            return "Care · \(event.type.label)"
        }
        if cost.consumptionID != nil {
            return "Feed · \(cost.ledgerLabel)"
        }
        return cost.ledgerLabel
    }

    static func typeCost(_ label: String, _ linked: [LivestockCostAttribution]) -> LivestockTypeCost? {
        guard !linked.isEmpty else { return nil }
        return LivestockTypeCost(label: label, amount: linked.reduce(Decimal(0)) { $0 + LivestockMoney.signed($1.amount) })
    }
}

struct LivestockHerd: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    var notes: String = ""
    var retiredAt: Date? = nil
    var careEvents: [LivestockCareEvent] = []
    var consumptions: [LivestockConsumption] = []
    var costs: [LivestockCostAttribution] = []

    var isRetired: Bool { retiredAt != nil }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LivestockHerd, rhs: LivestockHerd) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.notes == rhs.notes
            && lhs.retiredAt == rhs.retiredAt
            && lhs.careEvents == rhs.careEvents
            && lhs.consumptions == rhs.consumptions
            && lhs.costs == rhs.costs
    }

    func renaming(_ name: String) -> LivestockHerd {
        LivestockHerd(
            id: id,
            name: name,
            notes: notes,
            retiredAt: retiredAt,
            careEvents: careEvents,
            consumptions: consumptions,
            costs: costs
        )
    }

    var recordedCostTotal: Decimal { recordedBuckets.total }

    var recordedBuckets: LivestockCostBuckets {
        activeCosts.reduce(into: LivestockCostBuckets()) { buckets, item in
            buckets = buckets.adding(LivestockMoney.signed(item.amount), frequency: item.frequency)
        }
    }

    var activeCosts: [LivestockCostAttribution] {
        let removed = removedRecordIDs
        return costs.filter { $0.isCounted && $0.linkedRecordID.map { !removed.contains($0) } ?? true }
    }

    func isRemovedWithEvent(_ cost: LivestockCostAttribution) -> Bool {
        cost.isCounted && cost.linkedRecordID.map(removedRecordIDs.contains) == true
    }

    func eventCosts(_ recordID: UUID) -> [LivestockCostAttribution] {
        let ids = LivestockCorrectionTitle.chain(from: recordID, supersedes: recordSupersedes)
        return activeCosts.filter { $0.linkedRecordID.map(ids.contains) == true }
    }

    func eventCost(_ recordID: UUID) -> Decimal? {
        let linked = eventCosts(recordID)
        guard !linked.isEmpty else { return nil }
        return linked.reduce(Decimal(0)) { $0 + LivestockMoney.signed($1.amount) }
    }

    var careCostByType: [LivestockTypeCost] {
        LivestockCareEventType.allCases.compactMap { type in
            let ids = Set(careEvents.filter { $0.type == type }.map(\.id))
            return Animal.typeCost(type.label, activeCosts.filter { $0.careEventID.map(ids.contains) == true })
        }
    }

    var feedCostByType: [LivestockTypeCost] {
        LivestockInputType.allCases.compactMap { type in
            Animal.typeCost(type.label, activeCosts.filter { $0.consumptionID != nil && $0.feedType == type })
        }
    }

    func costLabel(_ cost: LivestockCostAttribution) -> String {
        if let id = cost.careEventID, let event = careEvents.first(where: { $0.id == id }) {
            return "Care · \(event.type.label)"
        }
        if cost.consumptionID != nil {
            return "Feed · \(cost.ledgerLabel)"
        }
        return cost.ledgerLabel
    }

    private var recordSupersedes: [UUID: UUID] {
        var supersedes: [UUID: UUID] = [:]
        for event in careEvents { supersedes[event.id] = event.supersedesID }
        for item in consumptions { supersedes[item.id] = item.supersedesID }
        return supersedes
    }

    private var removedRecordIDs: Set<UUID> {
        let supersedes = recordSupersedes
        let duplicates = careEvents.filter { $0.isCurrent && $0.correctionReason == .duplicateEntry }.map(\.id)
            + consumptions.filter { $0.isCurrent && $0.correctionReason == .duplicateEntry }.map(\.id)
        return duplicates.reduce(into: Set<UUID>()) { removed, id in
            removed.formUnion(LivestockCorrectionTitle.chain(from: id, supersedes: supersedes))
        }
    }
}

enum HerdSpeciesWarning {
    static func otherSpecies(assigning animal: Animal, to herdID: UUID, among animals: [Animal]) -> String? {
        let different = Set(animals.compactMap { candidate -> String? in
            guard candidate.herdID == herdID, candidate.id != animal.id else { return nil }
            return candidate.speciesDisplay == animal.speciesDisplay ? nil : candidate.speciesDisplay
        })
        guard !different.isEmpty else { return nil }
        return different.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: ", ")
    }
}

struct HerdAnimalGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let livestockNames: [String]
    let petNames: [String]
}

enum LivestockHerdMenu {
    static func assignable(_ herds: [LivestockHerd]) -> [LivestockHerd] {
        herds.filter { !$0.isRetired }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// SwiftUI keeps a Picker's current value in the menu even when that value
    /// is no longer in the option list. Retired herds must not stay selected.
    static func selection(_ herdID: UUID?, among herds: [LivestockHerd]) -> UUID? {
        guard let herdID, assignable(herds).contains(where: { $0.id == herdID }) else { return nil }
        return herdID
    }
}

enum HerdGrouping {
    static func groups(animals: [Animal], herds: [LivestockHerd]) -> [HerdAnimalGroup] {
        let current = animals.filter { !$0.isRetired }
        let ordered = LivestockHerdMenu.assignable(herds)
        var groups = ordered.map { herd in
            let members = current.filter { $0.herdID == herd.id }
            return HerdAnimalGroup(
                id: herd.id.uuidString,
                name: herd.name,
                livestockNames: members.filter { AnimalCategory.liveStock.includes($0.species) }.map(\.displayName).sorted(),
                petNames: members.filter { AnimalCategory.pets.includes($0.species) }.map(\.displayName).sorted()
            )
        }
        let unassigned = current.filter { $0.herdID == nil }
        groups.append(
            HerdAnimalGroup(
                id: "none",
                name: "No herd",
                livestockNames: unassigned.filter { AnimalCategory.liveStock.includes($0.species) }.map(\.displayName).sorted(),
                petNames: unassigned.filter { AnimalCategory.pets.includes($0.species) }.map(\.displayName).sorted()
            )
        )
        return groups
    }
}

struct HerdOverview: Equatable, Sendable {
    /// Count of animals in the current presentation. A fixture count is not a live herd total.
    let animalCount: Int
    let currentLivestock: Int
    let retiredLivestock: Int
    let currentPets: Int
    let retiredPets: Int
    let totalCost: Decimal

    static func from(animals: [Animal], herds: [LivestockHerd] = []) -> HerdOverview {
        let livestock = animals.filter { AnimalCategory.liveStock.includes($0.species) }
        let pets = animals.filter { AnimalCategory.pets.includes($0.species) }
        let animalCost = animals.reduce(Decimal(0)) { $0 + $1.recordedCostTotal }
        let herdCost = herds.reduce(Decimal(0)) { $0 + $1.recordedCostTotal }
        return HerdOverview(
            animalCount: animals.count,
            currentLivestock: livestock.filter { !$0.isRetired }.count,
            retiredLivestock: livestock.filter(\.isRetired).count,
            currentPets: pets.filter { !$0.isRetired }.count,
            retiredPets: pets.filter(\.isRetired).count,
            totalCost: animalCost + herdCost
        )
    }
}

enum FixtureLoadState: Equatable, Sendable {
    case loading
    case loaded
    case empty(message: String)
    case error(message: String)

    var message: String? {
        switch self {
        case .loading: "Loading fixture presentation…"
        case .loaded: nil
        case let .empty(message), let .error(message): message
        }
    }
}

enum FixturePresentationBoundary {
    static let tenantDisclosure = "DEV fixture — live tenant data is not connected."
    static let deferredSliceDisclosure = "Death, transfer, and Finance posting are not in this slice."
    static let careRecordBoundary = "Livestock care record. Ranch Health remains human-only."
    static let feedRecordBoundary = "Feed consumption stays here and does not change inventory."
    static let costRecordBoundary = "Operational cost only. Ranch Finance remains the ledger, and this does not post a bill or payment."
    static let careOwnership = "Livestock owns animal care records. Ranch Health remains human-only."
    static let financeOwnership = "Ranch Finance remains the canonical ledger; no posting or editing occurs here."
    static let addAnimalBoundary = "Fixture session only — Add animal does not write to a database or disk."
    static let createUnavailableBoundary = "Create animal is unavailable on a live or missing read."
    static let viewerCannotCreateBoundary = "A viewer cannot create an animal."
    static let createNeedsNameBoundary = "Display name is required."
    static let identifierBoundary = "Fixture session only — identifiers are not written to a database or disk."
    static let identifierUnavailableBoundary = "Assign and retire are unavailable on a live or missing read."
    static let viewerCannotAssignBoundary = "A viewer cannot assign or retire an identifier."
    static let identifierNeedsValueBoundary = "Identifier value is required."
    static let identifierActiveCollisionBoundary = "That identifier is already active in this fixture session."
    static let identifierAlreadyRetiredBoundary = "That identifier is already retired."
    static let lifecycleBoundary = "Fixture session only — routine lifecycle events are appended in time order and are not written to a database or disk."
    static let lifecycleUnavailableBoundary = "Lifecycle recording is unavailable on a live or missing read."
    static let viewerCannotRecordLifecycleBoundary = "A viewer cannot record a lifecycle event."
    static let ownerCorrectsLifecycleBoundary = "Only an owner can correct a lifecycle event."
    static let lifecycleCorrectionConfirmationBoundary = "A lifecycle correction requires confirmation."
    static let lifecycleAlreadyCorrectedBoundary = "That lifecycle event already has a correction."
    static let lifecycleOrderBoundary = "Routine lifecycle events must be later than the latest event for this animal."
    static var databaseWriteBoundary: String { "Saved in the \(LivestockBuildStamp.current.databaseLabel)." }
    static let saveConfirmsBoundary = "Save writes what you entered. Saving confirms surgery, vaccination, medication, and cost."
    static let saveNeedsEntryBoundary = "Enter an identifier, lifecycle event, care record, feed quantity, or cost, then save."
    static let retiredCorrectionBoundary = "Retirement is locked. You can correct existing care, feed, and cost. You cannot add new records."
    static let classificationStoredBoundary = "Species stays as recorded. Production type and breed can be changed."
    static let rejectedSpeciesBoundary = "Rabbit and other descriptions are not accepted by the durable catalog."
}
