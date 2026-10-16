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

    static var current: LivestockBuildStamp {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return LivestockBuildStamp(
            name: "Livestock Management",
            environment: "DEV",
            version: version.isEmpty ? "0.1.0" : version,
            build: build.isEmpty ? "1" : build
        )
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
        case .liveStock: "Current livestock"
        case .pets: "Current pets"
        }
    }
    var addLabel: String {
        switch self {
        case .liveStock: "Add live stock"
        case .pets: "Add pet"
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

    static func petBreeds(for kind: PetKind?) -> [String] {
        switch kind {
        case .dog: dogBreeds
        case .cat: catBreeds
        case .bird: birdBreeds
        case .reptile: reptileBreeds
        case .other, nil: []
        }
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
}

struct LivestockCareEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let type: LivestockCareEventType
    let occurredAt: Date
}

enum LivestockInputType: String, CaseIterable, Identifiable, Sendable {
    case feed, hay, mineral, supplement
    case dryFood = "dry_food"
    case wetFood = "wet_food"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .feed: "Feed"
        case .hay: "Hay"
        case .mineral: "Mineral"
        case .supplement: "Supplement"
        case .dryFood: "Dry food"
        case .wetFood: "Wet food"
        }
    }

    static func entryChoices(for species: Species) -> [LivestockInputType] {
        species == .pet ? [.dryFood, .wetFood, .supplement] : [.feed, .hay, .supplement]
    }
}

struct LivestockFeedEntry: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var inputType: LivestockInputType
    var quantity: String = ""
    var unit: LivestockInputUnit = .lb
    var frequency: LivestockCostFrequency = .daily
    var cost: String = ""

    var hasQuantity: Bool {
        !quantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    case lb, kg, bale, bag, scoop

    var id: String { rawValue }
    var label: String {
        switch self {
        case .lb: "Pounds"
        case .kg: "Kilograms"
        case .bale: "Bale"
        case .bag: "Bag"
        case .scoop: "Scoops"
        }
    }

    static let entryChoices: [LivestockInputUnit] = [.lb, .kg, .scoop, .bag]
}

enum LivestockCostFrequency: String, CaseIterable, Identifiable, Sendable {
    case daily, weekly, monthly, quarterly

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
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

    var summary: String {
        let base = "\(inputType.label) \(quantity) \(unit.label)"
        guard let frequency else { return base }
        return "\(base) · \(frequency.label)"
    }
}

enum LivestockMoney {
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
    var other: Decimal = 0

    var total: Decimal {
        let sum = daily + weekly + monthly + quarterly + other
        return sum < 0 ? 0 : sum
    }

    func adding(_ amount: Decimal, frequency: LivestockCostFrequency?) -> LivestockCostBuckets {
        var copy = self
        switch frequency {
        case .daily: copy.daily += amount
        case .weekly: copy.weekly += amount
        case .monthly: copy.monthly += amount
        case .quarterly: copy.quarterly += amount
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

    var summary: String {
        let money = "\(LivestockMoney.usd(LivestockMoney.nonNegative(amount))) per animal"
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
        if let financeReference, !financeReference.isEmpty {
            return "Operational · Finance \(financeReference)"
        }
        return "Operational"
    }
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
    static func days(from costs: [LivestockCostAttribution], calendar: Calendar = .current) -> [LivestockCostDay] {
        let grouped = Dictionary(grouping: costs) { calendar.startOfDay(for: $0.recordedAt) }
        return grouped.keys.sorted(by: >).map { day in
            let lines = (grouped[day] ?? []).sorted { lhs, rhs in
                if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
                return lhs.id.uuidString > rhs.id.uuidString
            }.map { cost in
                LivestockDatedCost(
                    id: cost.id,
                    label: cost.ledgerLabel,
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

    var summary: String { type.label }
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
        if let recordedBreed, !recordedBreed.isEmpty, recordedBreed != "mixed" {
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
            status: status
        )
    }

    var recordedCostTotal: Decimal { recordedBuckets.total }

    var recordedBuckets: LivestockCostBuckets {
        costs.reduce(into: LivestockCostBuckets()) { buckets, item in
            buckets = buckets.adding(LivestockMoney.signed(item.amount), frequency: item.frequency)
        }
    }
}

struct LivestockHerd: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    var notes: String = ""
    var retiredAt: Date? = nil

    var isRetired: Bool { retiredAt != nil }
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

enum HerdGrouping {
    static func groups(animals: [Animal], herds: [LivestockHerd]) -> [HerdAnimalGroup] {
        let current = animals.filter { !$0.isRetired }
        let ordered = herds.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

    static func from(animals: [Animal]) -> HerdOverview {
        let livestock = animals.filter { AnimalCategory.liveStock.includes($0.species) }
        let pets = animals.filter { AnimalCategory.pets.includes($0.species) }
        return HerdOverview(
            animalCount: animals.count,
            currentLivestock: livestock.filter { !$0.isRetired }.count,
            retiredLivestock: livestock.filter(\.isRetired).count,
            currentPets: pets.filter { !$0.isRetired }.count,
            retiredPets: pets.filter(\.isRetired).count,
            totalCost: animals.reduce(Decimal(0)) { $0 + $1.recordedCostTotal }
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
    static let lifecycleOrderBoundary = "Routine lifecycle events must be later than the latest event for this animal."
    static let databaseWriteBoundary = "Saved in the DEV livestock database."
    static let saveConfirmsBoundary = "Save writes what you entered. Saving confirms surgery, vaccination, medication, and cost."
    static let saveNeedsEntryBoundary = "Enter an identifier, lifecycle event, care record, feed quantity, or cost, then save."
    static let classificationStoredBoundary = "Species stays as recorded. Production type and breed can be changed."
    static let rejectedSpeciesBoundary = "Rabbit and other descriptions are not accepted by the durable catalog."
}
