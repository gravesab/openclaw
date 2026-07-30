BEGIN;

UPDATE propertymanager.maintenance_tasks
SET response_instructions = CASE item
    WHEN 'Spa: Clean and condition spa cover' THEN
        'Monthly: Apply a spa vinyl cleaner to the spa cover and pillows to protect them from chemical and ultraviolet-light damage. Do not use automotive vinyl protectants; the manual warns that their oil base can cause severe water-clarity problems. Source: Strong Spas manual, page 26.'
    WHEN 'Spa: Clean and reinstall filter' THEN
        '1. Turn the spa off and remove the filter. 2. Put the filter in a bucket with enough water to cover it and add 8 oz of liquid filter cleaner. 3. Soak for at least 24 hours. 4. Spray the filter pleats with a water hose. 5. Reinstall the filter. The manual recommends spraying off surface debris weekly and deep-cleaning monthly. Source: Strong Spas manual, page 23.'
    WHEN 'Spa: Drain, clean, and refill spa' THEN
        '1. Turn off power at the breaker and remove the filter. 2. Connect a garden hose to the drain fitting, route it to an approved disposal location, open the shut-off valve, and drain completely. 3. Close the valve and replace its cap. 4. Clean the cool, dry acrylic shell with a low-detergent, non-abrasive spa cleaner; wipe with a soft cloth, rinse thoroughly with a wet sponge, and let dry. 5. Refill through the filter chamber to 2 inches above the highest jet (excluding neck/shoulder jets), reinstall the filter, and restore power. Source: Strong Spas manual, pages 14 and 25.'
    WHEN 'Spa: Polish acrylic shell' THEN
        'After draining and cleaning the spa, polish the acrylic shell with an acrylic surface cleaner. Apply products only to a clean, cool, dry surface; do not use abrasive cleaners. Source: Strong Spas manual, pages 23 and 25.'
    WHEN 'Spa: Replace filter cartridge' THEN
        'Inspect the filter cartridge pleats. Replace the cartridge if the pleats appear frayed or damaged; replacement may be required more frequently depending on use. The manual also recommends replacement every 6 months or as necessary. Source: Strong Spas manual, page 23.'
    WHEN 'Spa: Replace ozonator' THEN
        'Replace the ozone generator approximately every 2 years. The manual identifies it as a wearable, non-warranty item and warns that ozone cannot be the sole means of maintaining safe spa water; continue using an approved chemical sanitizer. Source: Strong Spas manual, page 22.'
    WHEN 'Spa: Test and adjust pH balance' THEN
        '1. Test the water with test strips or a reagent test kit. 2. Confirm pH is between 7.2 and 7.6. 3. If pH is below the range, increase it with an appropriate spa-water product; if it is above the range, decrease it. 4. Follow the chemical product label instructions. Source: Strong Spas manual, pages 21-23.'
    WHEN 'Spa: Test and adjust sanitizer levels' THEN
        '1. Test sanitizer level with test strips or a reagent test kit and follow the sanitizer product''s target range. 2. Maintain either chlorine, bromine, or another spa-approved sanitizer even when an ozonator is installed. 3. If adding chlorine, keep bathers out, open all jets, and run the spa on high with the cover open for at least 30 minutes. Do not use trichlor tablets or liquid chlorine. Source: Strong Spas manual, page 22.'
    WHEN 'Spa: Test and reset GFCI' THEN
        'For a 120 V plug-and-play spa with a GFCI cord: 1. With the spa powered and operational, press TEST; the GFCI should trip and the spa should stop. 2. Press RESET; the GFCI should reset and the spa should resume. If it will not reset, unplug the spa, do not use it, and call the spa dealer for service. Source: Strong Spas manual, page 8. For other electrical configurations, use the procedure for the installed GFCI.'
    ELSE response_instructions
END
WHERE lower(area) = 'spa'
  AND origin = 'manufacturer'
  AND source_manual_name = 'Strong-Spas-Manual2020sm.pdf';

DO $$
DECLARE updated_count integer;
BEGIN
    SELECT count(*) INTO updated_count
    FROM propertymanager.maintenance_tasks
    WHERE lower(area) = 'spa'
      AND origin = 'manufacturer'
      AND source_manual_name = 'Strong-Spas-Manual2020sm.pdf'
      AND response_instructions NOT LIKE 'Follow Strong-Spas%';
    IF updated_count <> 9 THEN
        RAISE EXCEPTION 'Expected 9 updated Spa tasks, found %', updated_count;
    END IF;
END $$;

COMMIT;
