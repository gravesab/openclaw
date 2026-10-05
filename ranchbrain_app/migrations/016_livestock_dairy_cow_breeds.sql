-- DEV-only dairy cow breeds are dairy breeds. Other species lists stay as in 014.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 015.

BEGIN;

DO $$
DECLARE
    runtime_bypasses_rls boolean;
BEGIN
    IF current_user <> 'ranchos_dev_migrator' THEN
        RAISE EXCEPTION 'this DEV migration must run as ranchos_dev_migrator';
    END IF;
    SELECT rolbypassrls INTO runtime_bypasses_rls
    FROM pg_roles
    WHERE rolname = 'ranchos_dev_runtime';
    IF runtime_bypasses_rls IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'ranchos_dev_runtime must not have BYPASSRLS';
    END IF;
END;
$$;

ALTER TABLE ranchos.livestock_animals
    DROP CONSTRAINT livestock_animals_breed_matches_species;

ALTER TABLE ranchos.livestock_animals
    ADD CONSTRAINT livestock_animals_breed_matches_species CHECK (
        breed_code IS NULL OR
        (species_code = 'cattle' AND breed_code IN (
            'angus', 'ayrshire', 'beefmaster', 'belted_galloway',
            'brahman', 'brangus', 'brown_swiss', 'charolais',
            'chianina', 'corriente', 'devon', 'dexter',
            'dutch_belted', 'galloway', 'gelbvieh', 'guernsey',
            'hereford', 'highland', 'holstein', 'jersey',
            'limousin', 'maine_anjou', 'milking_shorthorn', 'murray_grey',
            'normande', 'piedmontese', 'pinzgauer', 'red_angus',
            'red_poll', 'salers', 'santa_gertrudis', 'shorthorn',
            'simmental', 'south_devon', 'tarentaise', 'texas_longhorn',
            'wagyu'
        )) OR
        (species_code = 'dairy_cow' AND breed_code IN (
            'ayrshire', 'brown_swiss', 'canadienne', 'danish_red',
            'dutch_belted', 'guernsey', 'holstein', 'illawarra',
            'jersey', 'kerry', 'milking_shorthorn', 'montbeliarde',
            'normande', 'norwegian_red', 'randall', 'swedish_red'
        )) OR
        (species_code = 'bison' AND breed_code IN (
            'american_bison', 'beefalo', 'wood_bison'
        )) OR
        (species_code = 'goat' AND breed_code IN (
            'alpine', 'angora', 'boer', 'kalahari_red',
            'kiko', 'kinder', 'lamancha', 'myotonic',
            'nigerian_dwarf', 'nubian', 'oberhasli', 'pygmy',
            'saanen', 'savanna', 'spanish', 'toggenburg'
        )) OR
        (species_code = 'sheep' AND breed_code IN (
            'barbados_blackbelly', 'bluefaced_leicester', 'border_leicester', 'cheviot',
            'clun_forest', 'columbia', 'corriedale', 'dorper',
            'dorset', 'finnsheep', 'gulf_coast', 'hampshire',
            'icelandic_sheep', 'jacob', 'katahdin', 'lincoln',
            'merino', 'navajo_churro', 'oxford', 'polypay',
            'rambouillet', 'romney', 'shetland_sheep', 'shropshire',
            'southdown', 'st_croix', 'suffolk', 'texel',
            'tunis'
        )) OR
        (species_code = 'chicken' AND breed_code IN (
            'ameraucana', 'ancona', 'araucana', 'australorp',
            'barnevelder', 'brahma', 'buckeye', 'buttercup',
            'campine', 'chantecler', 'chicken_andalusian', 'chicken_spanish',
            'cochin', 'cornish', 'cornish_cross', 'crevecoeur',
            'cubalaya', 'delaware', 'dominique', 'dorking',
            'easter_egger', 'faverolles', 'hamburg', 'holland',
            'houdan', 'java', 'jersey_giant', 'la_fleche',
            'lakenvelder', 'langshan', 'leghorn', 'malay',
            'marans', 'minorca', 'modern_game', 'naked_neck',
            'new_hampshire', 'old_english_game', 'orpington', 'phoenix',
            'plymouth_rock', 'polish', 'rhode_island_red', 'rhode_island_white',
            'sebright', 'silkie', 'sultan', 'sumatra',
            'sussex', 'welsummer', 'wyandotte', 'yokohama'
        )) OR
        (species_code = 'pig' AND breed_code IN (
            'berkshire', 'chester_white', 'duroc', 'gloucestershire_old_spots',
            'guinea_hog', 'hereford_hog', 'landrace', 'large_black',
            'mangalitsa', 'meishan', 'mulefoot', 'ossabaw',
            'pig_hampshire', 'red_wattle', 'spotted', 'tamworth',
            'yorkshire'
        )) OR
        (species_code = 'horse' AND breed_code IN (
            'andalusian', 'appaloosa', 'arabian', 'belgian',
            'clydesdale', 'fjord', 'friesian', 'gypsy_vanner',
            'haflinger', 'icelandic_horse', 'miniature', 'missouri_fox_trotter',
            'morgan', 'mustang', 'paint', 'paso_fino',
            'percheron', 'quarter_horse', 'rocky_mountain', 'saddlebred',
            'shetland_pony', 'shire', 'standardbred', 'tennessee_walker',
            'thoroughbred', 'warmblood', 'welsh_pony'
        ))
    );

COMMIT;
