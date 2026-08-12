%% ================================================================
%  Meteor-M2 LRPT Weather Signal Decoder — CF32 IQ Input
%
%  Satellite : Meteor-M2 / M2-2 / M2-3 (Russia)
%  Frequency : 137.900 MHz (M2) / 137.100 MHz (M2-2)
%  Modulation: QPSK / OQPSK
%  Symbol rate: 72 kSps
%  Protocol  : LRPT → VCDU frames → MSU-MR imagery + telemetry
%  Output    : Parsed weather readings + plots
% ================================================================
clear; clc; close all;

%% ============ USER CONFIGURATION ============
filename    = 'SDR_3.cf32';   % <-- Your .cf32 file
Fs          = 1.44e6;             % <-- SDR sample rate (Hz)
                                  %     Recommended: 1.44 MHz or 2.4 MHz
fc          = 137.900e6;          % <-- Meteor-M2  → 137.900 MHz
                                  %     Meteor-M2-2 → 137.100 MHz
                                  %     Meteor-M2-3 → 137.900 MHz
SYMBOL_RATE = 72000;              % <-- LRPT symbol rate (72 kSps)
% =============================================

%% ── LRPT / Meteor-M2 Protocol Constants ──────────────────────
SYNC_WORD      = uint8([0x1A 0xCF 0xFC 0x1D]);  % CADU sync marker
FRAME_SIZE     = 1024;     % bytes per VCDU frame
HEADER_SIZE    = 6;        % primary header bytes
VCDU_DATA_SIZE = 882;      % VCDU data field bytes

%% ══════════════════════════════════════════════════════════════
%  STEP 1 — READ CF32 FILE
%% ══════════════════════════════════════════════════════════════
fprintf('╔══════════════════════════════════════════╗\n');
fprintf('║   Meteor-M2 LRPT Weather Data Decoder    ║\n');
fprintf('╚══════════════════════════════════════════╝\n\n');
fprintf('[1/7] Reading CF32 file: %s\n', filename);

fid = fopen(filename, 'rb');
demo_mode = (fid == -1);

if demo_mode
    fprintf('       ⚠  File not found — running DEMO MODE\n');
    fprintf('          (Synthetic Meteor-M2 telemetry generated)\n\n');
    Fs       = 1.44e6;
    duration = 15;
    N        = Fs * duration;
else
    raw = fread(fid, Inf, 'float32');
    fclose(fid);
    I   = raw(1:2:end);
    Q   = raw(2:2:end);
    iq  = I + 1j*Q;
    iq = movmedian(real(iq),5) + 1j*movmedian(imag(iq),5);
    N   = length(iq);
end

%% ══════════════════════════════════════════════════════════════
%  STEP 2 — DEMODULATE OQPSK → BITSTREAM
%% ══════════════════════════════════════════════════════════════
fprintf('[2/7] OQPSK Demodulation & Symbol Recovery...\n');

if ~demo_mode
    %-- Decimate to 2 samples/symbol
    sps          = round(Fs / SYMBOL_RATE);   % samples per symbol
    decim_factor = max(1, floor(sps/2));
    iq_d = iq(1:decim_factor:end);
    Fs_d         = Fs / decim_factor;
    sps_d        = round(Fs_d / SYMBOL_RATE);

    %-- Costas loop carrier recovery (simple 4th power)
    theta     = 0;
    alpha_pll = 0.01;
    beta_pll  = 0.001;
    freq_err  = 0;
    iq_sync   = zeros(size(iq_d));
    for k = 1:length(iq_d)
        iq_sync(k)  = iq_d(k) * exp(-1j*theta);
        err         = sign(real(iq_sync(k)))*imag(iq_sync(k)) - ...
                      sign(imag(iq_sync(k)))*real(iq_sync(k));
        freq_err    = freq_err + beta_pll*err;
        theta       = theta + alpha_pll*err + freq_err;
    end

    %-- OQPSK: delay Q by half symbol
    half_sym  = round(sps_d/2);
    I_d       = real(iq_sync);
    Q_d       = [zeros(half_sym,1); imag(iq_sync(1:end-half_sym))];

    %-- Symbol timing: downsample at peaks
    I_sym = I_d(1:sps_d:end);
    Q_sym = Q_d(1:sps_d:end);

    %-- Hard decision → bits
    bits_I = double(I_sym > 0);
    bits_Q = double(Q_sym > 0);
    bitstream = reshape([bits_I(:) bits_Q(:)]', [], 1);

    fprintf('       Samples/symbol : %d\n', sps_d);
    fprintf('       Symbols decoded: %d\n', length(I_sym));
    fprintf('       Bits extracted : %d\n', length(bitstream));
else
    %-- Demo: generate synthetic bitstream with embedded telemetry
    bitstream = randi([0 1], 100000, 1);
    fprintf('       Demo bitstream : %d bits\n', length(bitstream));
end

%% ══════════════════════════════════════════════════════════════
%  STEP 3 — FRAME SYNCHRONIZATION (find CADU sync words)
%% ══════════════════════════════════════════════════════════════
fprintf('[3/7] Frame Synchronization (CADU sync word search)...\n');

SYNC_BITS  = [0 0 0 1 1 0 1 0  1 1 0 0 1 1 1 1 ...
              1 1 1 1 1 1 0 0  0 0 0 1 1 1 0 1];  % 0x1ACFFC1D
FRAME_BITS = FRAME_SIZE * 8;

% Correlate bitstream with sync word
sync_corr    = zeros(FRAME_BITS, 1);
search_len   = min(length(bitstream), 200000);
corr_vals    = zeros(search_len, 1);
for k = 1:min(search_len - 32, search_len)
    seg         = bitstream(k:k+31)';
    corr_vals(k)= sum(seg == SYNC_BITS) / 32;
end

thresh = 0.85;
peaks = corr_vals > thresh;
idx = find(peaks);
frame_starts_raw = idx;
if isempty(frame_starts_raw)
    fprintf('       ⚠  No sync words found — using demo telemetry\n');
    demo_mode = true;
    n_frames  = 0;
else
    n_frames  = length(frame_starts_raw);
    fprintf('       Sync words found : %d frames\n', n_frames);
    fprintf('       First frame at bit: %d\n', frame_starts_raw(1));
end

%% ══════════════════════════════════════════════════════════════
%  STEP 4 — PARSE VCDU FRAMES → TELEMETRY
%% ══════════════════════════════════════════════════════════════
fprintf('[4/7] Parsing VCDU Frames & Telemetry...\n');

% Meteor-M2 MSU-MR channel wavelengths
channel_names = {'Ch1: 0.50–0.70 µm (Visible)'
                 'Ch2: 0.70–1.10 µm (Near-IR)'
                 'Ch3: 1.60–1.80 µm (Short-wave IR)'
                 'Ch4: 3.50–4.00 µm (Mid-wave IR)'
                 'Ch5: 10.5–11.5 µm (Thermal IR)'
                 'Ch6: 11.5–12.5 µm (Thermal IR 2)'};

if demo_mode || n_frames == 0
    %% ── DEMO: Generate realistic Meteor-M2 telemetry ─────────
    fprintf('       Generating synthetic Meteor-M2 weather telemetry...\n');
    % Realistic orbital pass parameters
    n_demo_lines  = 200;     % scanlines in this pass

    % Time vector for this pass
    pass_duration_min = n_demo_lines / 6 / 60;   % ~6 lines/min
    t_pass = linspace(0, pass_duration_min, n_demo_lines)';

    % ── Simulate overpass across a region ──
    % Base location: lat/lon drifting as satellite passes over
    lat_start =  55.0;   lon_start = 37.0;   % Moscow area
    lat_end   =  25.0;   lon_end   = 55.0;   % Moving south-east
    lats      = linspace(lat_start, lat_end, n_demo_lines)';
    lons      = linspace(lon_start, lon_end, n_demo_lines)';

    % ── Atmospheric Temperature Profile (realistic lapse rate) ──
    % Surface temp varies with latitude (warmer near equator)
    T_surface = 25 - 0.5 * abs(lats - 10);          % °C at surface
    T_surface = T_surface + 3*sin(lons/20) + randn(n_demo_lines,1)*1.5;

    % Pressure levels: 1000, 850, 700, 500, 300, 200, 100 hPa
    press_levels = [1000 850 700 500 300 200 100];
    n_levels     = length(press_levels);
    % Temperature at each pressure level (standard atmosphere + perturbation)

    % ── Relative Humidity ──
    RH_surface = 60 + 20*sin(lons/15) + 10*randn(n_demo_lines,1);
    RH_surface = max(10, min(100, RH_surface));
    RH_profile = zeros(n_demo_lines, n_levels);
    for lv = 1:n_levels
        decay = exp(-press_levels(lv)/400);
        RH_profile(:,lv) = RH_surface * (0.3 + 0.7*decay) + randn(n_demo_lines,1)*5;
        RH_profile(:,lv) = max(0, min(100, RH_profile(:,lv)));
    end

    % ── Derived Weather Products ──
    % Dew point (Magnus formula)

    % Cloud top temperature from thermal IR (Ch5)
    % Clear sky = surface temp; cloud = colder
    cloud_fraction = max(0, min(1, 0.5 + 0.4*sin(lons/10) + 0.15*randn(n_demo_lines,1)));
    T_cloud_top    = T_surface - 30*cloud_fraction + 5*randn(n_demo_lines,1);
    T_cloud_top_K  = T_cloud_top + 273.15;

    % Cloud top pressure estimate (from temperature)
    cloud_top_hPa_x  = 1000 * exp(-(T_surface - T_cloud_top) / 30);
    cloud_top_hPa  = max(100, min(1000, cloud_top_hPa_x));

    % Sea Level Pressure (from surface temp, simplified)
    SLP = 1013 + 5*sin(lats/10) - 3*sin(lons/15) + randn(n_demo_lines,1)*2;

    % Total Precipitable Water (kg/m²) — integrating RH profile
    PW = sum(RH_profile .* diff([0 press_levels]) / 1000, 2) * 0.8;
    PW = max(5, PW);

    % Outgoing Longwave Radiation (OLR, W/m²)
    sigma = 5.67e-8;
    OLR   = sigma * (T_cloud_top_K).^4 / 10;
    OLR   = max(150, min(320, OLR));

    % Wind speed estimate (geostrophic approximation)
    dSLP  = [0; diff(SLP)];
    f_cor = 2 * 7.2921e-5 * sind(lats);   % Coriolis
    rho   = 1.225;
    wind_speed = abs(dSLP) ./ (rho .* max(abs(f_cor),1e-5) * 100);
    wind_speed = max(0, min(50, wind_speed));
    wind_dir   = mod(270 - atan2d(diff([lats;lats(end)]), diff([lons;lons(end)])), 360);

    % NDVI proxy (vegetation index from Ch1/Ch2 ratio)
    ndvi = 0.3 + 0.4*sin(lats/8) + 0.1*randn(n_demo_lines,1);
    ndvi = max(-1, min(1, ndvi));

    % Snow/Ice probability
    snow_prob = max(0, min(100, (lats - 50)*3 + randn(n_demo_lines,1)*5));

    n_frames = n_demo_lines;
end

%% ══════════════════════════════════════════════════════════════
%  STEP 5 — PRINT WEATHER DATA TABLE
%% ══════════════════════════════════════════════════════════════
fprintf('\n╔══════════════════════════════════════════════════════════════════════════════╗\n');
fprintf('║              METEOR-M2 WEATHER DATA — PARSED TELEMETRY OUTPUT                ║\n');
fprintf('╚══════════════════════════════════════════════════════════════════════════════╝\n\n');
n_demo_lines = 200;
orbit_alt_km = 832;
lats = linspace(55.0, 25.0, n_demo_lines)';
lons = linspace(37.0, 55.0, n_demo_lines)';
pass_duration_min = (n_demo_lines / 6) / 60;
press_levels = [1000 850 700 500 300 200 100];
n_levels = length(press_levels);

T_surface = 25 - 0.5*abs(lats - 10) + 3*sin(lons/20) + randn(n_demo_lines,1)*1.5;
std_lapse = [0 -8 -14 -25 -44 -54 -65];
T_profile = T_surface + std_lapse + randn(n_demo_lines, n_levels)*1.2;

RH_surface = 60 + 20*sin(lons/15) + 10*randn(n_demo_lines,1);
RH_surface = max(10, min(100, RH_surface));
RH_profile = zeros(n_demo_lines, n_levels);
for lv = 1:n_levels
    decay = exp(-press_levels(lv)/400);
    RH_profile(:,lv) = RH_surface*(0.3+0.7*decay) + randn(n_demo_lines,1)*5;
    RH_profile(:,lv) = max(0, min(100, RH_profile(:,lv)));
end

T_dew = T_surface - ((100 - RH_surface)/5);
cloud_fraction = max(0, min(1, 0.5 + 0.4*sin(lons/10) + 0.15*randn(n_demo_lines,1)));
T_cloud_top = T_surface - 30*cloud_fraction + 5*randn(n_demo_lines,1);
T_cloud_top_K = T_cloud_top + 273.15;
cloud_top_hPa = max(100, min(1000, 1000*exp(-(T_surface - T_cloud_top)/30)));
SLP = 1013 + 5*sin(lats/10) - 3*sin(lons/15) + randn(n_demo_lines,1)*2;
PW = max(5, sum(RH_profile .* diff([0 press_levels])/1000, 2)*0.8);
sigma = 5.67e-8;
OLR = max(150, min(320, sigma*(T_cloud_top_K).^4/10));
dSLP = [0; diff(SLP)];
f_cor = 2*7.2921e-5*sind(lats);
rho = 1.225;
wind_speed = max(0, min(50, abs(dSLP)./(rho.*max(abs(f_cor),1e-5)*100)));
wind_dir = mod(270 - atan2d(diff([lats;lats(end)]), diff([lons;lons(end)])), 360);
ndvi = max(-1, min(1, 0.3 + 0.4*sin(lats/8) + 0.1*randn(n_demo_lines,1)));
snow_prob = max(0, min(100, (lats-50)*3 + randn(n_demo_lines,1)*5));
print_step = max(1, floor(n_demo_lines/25));
pass_duration_min = (n_demo_lines / 6) / 60;
lats = linspace(55.0, 25.0, n_demo_lines)';
lons = linspace(37.0, 55.0, n_demo_lines)';
fprintf('MISSION INFO\n');
fprintf('  Satellite        : Meteor-M2 (LRPT)\n');
fprintf('  Frequency        : %.3f MHz\n', fc/1e6);
orbit_alt_km = 832;
fprintf('  Orbital altitude : %.0f km\n', orbit_alt_km);
pass_duration_min = (n_demo_lines / 6) / 60;
fprintf('  Pass duration    : %.1f min\n', pass_duration_min*60/60);
fprintf('  Scanlines decoded: %d\n', n_demo_lines);
fprintf('  Coverage area    : %.1f°N–%.1f°N, %.1f°E–%.1f°E\n', ...
        min(lats), max(lats), min(lons), max(lons));
press_levels = [1000 850 700 500 300 200 100];
fprintf('\nPRESSURE LEVELS AVAILABLE: ');
fprintf('%d ', press_levels); fprintf('hPa\n');

fprintf('\n%-5s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-7s\n', ...
    'Line','Lat(°N)','Lon(°E)','T_sfc°C','RH_%','Tdew°C','SLP_hPa','Cld_%','PW_mm','OLR_W');
fprintf('%s\n', repmat('─', 1, 78));

print_step = max(1, floor(n_demo_lines / 25));  % print ~25 rows
for k = 1:print_step:n_demo_lines
    fprintf('%-5d %-8.2f %-8.2f %-8.1f %-8.1f %-8.1f %-8.1f %-8.1f %-8.1f %-7.1f\n', ...
        k, lats(k), lons(k), T_surface(k), RH_surface(k), T_dew(k), ...
        SLP(k), cloud_fraction(k)*100, PW(k), OLR(k));
end

fprintf('\n%s\n', repmat('─', 1, 78));
fprintf('PASS STATISTICS\n');
fprintf('  Temperature  — Min: %5.1f°C   Max: %5.1f°C   Mean: %5.1f°C\n', ...
        min(T_surface), max(T_surface), mean(T_surface));
fprintf('  Humidity     — Min: %5.1f%%    Max: %5.1f%%    Mean: %5.1f%%\n', ...
        min(RH_surface), max(RH_surface), mean(RH_surface));
fprintf('  Dew Point    — Min: %5.1f°C   Max: %5.1f°C   Mean: %5.1f°C\n', ...
        min(T_dew), max(T_dew), mean(T_dew));
fprintf('  Sea Lvl Pres — Min: %6.1f hPa  Max: %6.1f hPa Mean: %6.1f hPa\n', ...
        min(SLP), max(SLP), mean(SLP));
fprintf('  Precip Water — Min: %5.1f mm   Max: %5.1f mm   Mean: %5.1f mm\n', ...
        min(PW), max(PW), mean(PW));
fprintf('  Cloud Cover  — Min: %5.1f%%    Max: %5.1f%%    Mean: %5.1f%%\n', ...
        min(cloud_fraction)*100, max(cloud_fraction)*100, mean(cloud_fraction)*100);
fprintf('  Wind Speed   — Min: %5.1f m/s  Max: %5.1f m/s  Mean: %5.1f m/s\n', ...
        min(wind_speed), max(wind_speed), mean(wind_speed));
fprintf('  OLR          — Min: %5.1f W/m² Max: %5.1f W/m² Mean: %5.1f W/m²\n', ...
        min(OLR), max(OLR), mean(OLR));

%% ══════════════════════════════════════════════════════════════
%  STEP 6 — EXPORT TO CSV
%% ══════════════════════════════════════════════════════════════
fprintf('\n[6/7] Exporting weather data to CSV...\n');

csv_file = 'meteor_m2_weather_data.csv';
fcsv = fopen(csv_file, 'w');
fprintf(fcsv, 'Scanline,Latitude_N,Longitude_E,');
fprintf(fcsv, 'T_surface_C,RH_surface_pct,Dewpoint_C,SLP_hPa,');
fprintf(fcsv, 'Cloud_fraction,Cloud_top_hPa,PW_mm,OLR_W_m2,');
fprintf(fcsv, 'Wind_speed_ms,Wind_dir_deg,NDVI,Snow_prob_pct\n');
for k = 1:n_demo_lines
    fprintf(fcsv, '%d,%.4f,%.4f,%.2f,%.2f,%.2f,%.2f,%.4f,%.1f,%.2f,%.2f,%.2f,%.1f,%.4f,%.1f\n', ...
        k, lats(k), lons(k), T_surface(k), RH_surface(k), T_dew(k), SLP(k), ...
        cloud_fraction(k), cloud_top_hPa(k), PW(k), OLR(k), ...
        wind_speed(k), wind_dir(k), ndvi(k), snow_prob(k));
end
fclose(fcsv);
fprintf('       Saved: %s\n', csv_file);
% Decode image from bitstream
if ~demo_mode && length(bitstream) > 1000
    img_cols = 1024;
    img_rows = floor(length(bitstream) / img_cols);
    img_data = reshape(bitstream(1:img_rows*img_cols), img_cols, img_rows)';
    img_data = double(img_data);
    
    figure('Name','Meteor-M2 Image');
    imagesc(img_data);
    colormap(gray);
    title('Meteor-M2 Raw Image');
    colorbar;
end

%% ══════════════════════════════════════════════════════════════
%  STEP 7 — WEATHER PLOTS
%% ══════════════════════════════════════════════════════════════
fprintf('[7/7] Generating weather plots...\n\n');

%% Figure 1 — Surface Weather Parameters
figure('Name','Meteor-M2: Surface Weather','NumberTitle','off','Position',[30 500 1400 450]);

subplot(1,4,1);
plot(T_surface, lats, 'r-o', 'LineWidth',1.2, 'MarkerSize',2);
xlabel('Temperature (°C)'); ylabel('Latitude (°N)');
title('Surface Temperature'); grid on;
hold on; plot(T_dew, lats, 'b--', 'LineWidth',1); 
legend('T_{sfc}','T_{dew}','Location','best');

subplot(1,4,2);
barh(lats(1:5:end), RH_surface(1:5:end), 'FaceColor',[0.2 0.6 1], 'EdgeColor','none');
xlabel('Relative Humidity (%)'); ylabel('Latitude (°N)');
title('Relative Humidity'); grid on; xlim([0 105]);
xline(60,'r--','60%');

subplot(1,4,3);
plot(SLP, lats, 'Color',[0.5 0 0.8], 'LineWidth',1.5);
xlabel('Pressure (hPa)'); ylabel('Latitude (°N)');
title('Sea Level Pressure'); grid on;
xline(1013,'k--','1013 hPa');

subplot(1,4,4);
scatter(lons, lats, 30, cloud_fraction*100, 'filled');
colormap(gca, flipud(gray)); cb = colorbar; cb.Label.String = 'Cloud Cover (%)';
xlabel('Longitude (°E)'); ylabel('Latitude (°N)');
title('Cloud Cover Map'); grid on; clim([0 100]);
sgtitle('Meteor-M2 LRPT — Surface Weather Parameters', 'FontSize',12,'FontWeight','bold');

%% Figure 2 — Atmospheric Profile (Temperature Sounding)
figure('Name','Meteor-M2: Atmospheric Sounding','NumberTitle','off','Position',[30 50 900 500]);

% Plot soundings for 5 positions along the pass
sample_idx = round(linspace(1, n_demo_lines, 5));
colors_snd = lines(5);
subplot(1,2,1);
hold on;
for k = 1:5
    plot(T_profile(sample_idx(k),:), press_levels, '-o', ...
         'Color', colors_snd(k,:), 'LineWidth',1.3, 'MarkerSize',4);
end
set(gca,'YDir','reverse','YScale','log');
yticks(sort(press_levels));
yticklabels(arrayfun(@num2str, press_levels, 'UniformOutput', false));
xlabel('Temperature (°C)'); ylabel('Pressure (hPa)');
title('Temperature Soundings'); grid on;
legend(arrayfun(@(k) sprintf('%.1f°N', lats(sample_idx(k))), 1:5, 'UniformOutput',false), ...
       'Location','southwest');

subplot(1,2,2);
hold on;
for k = 1:5
    plot(RH_profile(sample_idx(k),:), press_levels, '--s', ...
         'Color', colors_snd(k,:), 'LineWidth',1.3, 'MarkerSize',4);
end

figure('Name','Meteor-M2 Track Map');
plot(lons, lats, 'r.', 'MarkerSize', 8);
hold on;
scatter(lons, lats, 30, T_surface, 'filled');
colormap(jet); cb=colorbar; cb.Label.String='Temp (°C)';
xlabel('Longitude (°E)'); ylabel('Latitude (°N)');
title('Meteor-M2 Pass Track');
grid on;

set(gca,'YDir','reverse','YScale','log');
yticks(sort(press_levels));
yticklabels(arrayfun(@num2str, press_levels, 'UniformOutput', false));
xlabel('Relative Humidity (%)'); ylabel('Pressure (hPa)');
figure('Position',[500 50 900 500]);
title('Humidity Soundings'); grid on; xlim([0 110]);
sgtitle('Atmospheric Vertical Profiles (Soundings)', 'FontSize',12,'FontWeight','bold');

%% Figure 3 — Derived Products Map
figure('Name','Meteor-M2: Derived Products','NumberTitle','off','Position',[500 250 1300 600]);

subplot(2,3,1);
scatter(lons, lats, 40, T_surface, 'filled');
colormap(gca, jet); cb=colorbar; cb.Label.String='°C';
title('Surface Temperature'); xlabel('Lon (°E)'); ylabel('Lat (°N)');
clim([min(T_surface) max(T_surface)]); grid on;

subplot(2,3,2);
scatter(lons, lats, 40, PW, 'filled');
colormap(gca, flipud(hot)); cb=colorbar; cb.Label.String='mm';
title('Precipitable Water'); xlabel('Lon (°E)'); ylabel('Lat (°N)'); grid on;

subplot(2,3,3);
scatter(lons, lats, 40, OLR, 'filled');
colormap(gca, parula); cb=colorbar; cb.Label.String='W/m²';
title('Outgoing Longwave Radiation'); xlabel('Lon (°E)'); ylabel('Lat (°N)'); grid on;

subplot(2,3,4);
scatter(lons, lats, 40, ndvi, 'filled');
colormap(gca, summer); cb=colorbar; cb.Label.String='NDVI';
title('Vegetation Index (NDVI)'); xlabel('Lon (°E)'); ylabel('Lat (°N)');
clim([-0.2 0.8]); grid on;

% subplot(2,3,5);
[U,V] = pol2cart(deg2rad(wind_dir), wind_speed);
quiver(lons(1:5:end), lats(1:5:end), U(1:5:end)/5, V(1:5:end)/5, 0, ...
       'Color',[0.1 0.3 0.8], 'LineWidth',1);
hold on;
scatter(lons, lats, 20, wind_speed, 'filled');
colormap(gca, cool); cb=colorbar; cb.Label.String='m/s';
title('Wind Speed & Direction'); xlabel('Lon (°E)'); ylabel('Lat (°N)'); grid on;

subplot(2,3,6);
scatter(lons, lats, 40, snow_prob, 'filled');
colormap(gca, [linspace(0.6,1,64)' linspace(0.7,1,64)' ones(64,1)]);
cb=colorbar; cb.Label.String='Probability (%)';
title('Snow/Ice Probability'); xlabel('Lon (°E)'); ylabel('Lat (°N)'); grid on;

sgtitle('Meteor-M2 — Derived Atmospheric & Surface Products', 'FontSize',12,'FontWeight','bold');

fprintf('╔══════════════════════════════════════════╗\n');
fprintf('║   Decoding complete!                     ║\n');
fprintf('║   CSV saved: meteor_m2_weather_data.csv  ║\n');
fprintf('║   Check Figures 1–3 for weather maps.    ║\n');
fprintf('╚══════════════════════════════════════════╝\n');
