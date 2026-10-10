##############################################################################
# $Id: 98_DEXCOM.pm 2026-10-10 $
#
# 98_DEXCOM.pm - Dexcom Share Glukosewerte direkt in FHEM
#
# Liest den aktuellen Glukosewert samt Trend ueber die (inoffizielle)
# Dexcom-Share-Schnittstelle, dieselbe, die die Dexcom-Follow-App und die
# Home-Assistant-Integration (pydexcom) verwenden.
#
# Ablauf:  AuthenticatePublisherAccount -> accountId
#          LoginPublisherAccountById    -> sessionId
#          ReadPublisherLatestGlucoseValues (alle <interval> Sekunden)
#
# Wichtig: Nach einer abgelehnten Anmeldung wird NICHT erneut versucht, bis
# die Zugangsdaten mit "set <name> account" neu gesetzt werden. Dexcom sperrt
# das Konto sonst nach zu vielen Fehlversuchen (betrifft dann auch die App).
#
# Keine Medizinprodukt-Funktion. Fuer Therapieentscheidungen und Alarme ist
# ausschliesslich die Dexcom-App massgeblich.
#
# Autor:  TechTobi83
# Dank:   Ablauf und Fehlercodes der Share-Schnittstelle nach pydexcom
#         (https://github.com/gagebenne/pydexcom, MIT-Lizenz).
# Dexcom ist eine Marke der Dexcom, Inc. Dieses Modul steht in keiner
# Verbindung zu Dexcom.
#
# This file is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 2 of the License, or (at your option)
# any later version. It is distributed WITHOUT ANY WARRANTY; see
# <https://www.gnu.org/licenses/> for details.
##############################################################################

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use POSIX qw(strftime);

my %DEXCOM_baseUrl = (
  us  => 'https://share2.dexcom.com/ShareWebServices/Services/',
  ous => 'https://shareous1.dexcom.com/ShareWebServices/Services/',
  jp  => 'https://share.dexcom.jp/ShareWebServices/Services/',
);

my %DEXCOM_appId = (
  us  => 'd89443d2-327c-4a6f-89e5-496bbb0317db',
  ous => 'd89443d2-327c-4a6f-89e5-496bbb0317db',
  jp  => 'd8665ade-9673-4e27-9ff6-92db4ce13d13',
);

my $DEXCOM_defaultUuid = '00000000-0000-0000-0000-000000000000';

# Trend: Dexcom-Code -> [Pfeil, Text]; Index = alter numerischer Trendwert
my @DEXCOM_trends = (
  [ 'None',           '',   '' ],
  [ 'DoubleUp',       '↑↑', 'stark steigend' ],
  [ 'SingleUp',       '↑',  'steigend' ],
  [ 'FortyFiveUp',    '↗',  'leicht steigend' ],
  [ 'Flat',           '→',  'stabil' ],
  [ 'FortyFiveDown',  '↘',  'leicht fallend' ],
  [ 'SingleDown',     '↓',  'fallend' ],
  [ 'DoubleDown',     '↓↓', 'stark fallend' ],
  [ 'NotComputable',  '?',  'unbestimmt' ],
  [ 'RateOutOfRange', '-',  'nicht verfügbar' ],
);

# Fehlercodes, bei denen keine weitere Anmeldung versucht werden darf
my %DEXCOM_authFatal = map { $_ => 1 } qw(
  AccountPasswordInvalid
  SSO_AuthenticateMaxAttemptsExceeded
  SSO_AuthenticatePasswordInvalid
  SSO_AuthenticateAccountNotFound
);

sub DEXCOM_Initialize {
  my ($hash) = @_;
  $hash->{DefFn}    = 'DEXCOM_Define';
  $hash->{UndefFn}  = 'DEXCOM_Undef';
  $hash->{DeleteFn} = 'DEXCOM_Delete';
  $hash->{RenameFn} = 'DEXCOM_Rename';
  $hash->{SetFn}    = 'DEXCOM_Set';
  $hash->{AttrFn}   = 'DEXCOM_Attr';
  $hash->{AttrList} = 'region:ous,us,jp interval disable:0,1 rangeLow rangeHigh hypoLimit ' . $readingFnAttributes;
  return;
}

sub DEXCOM_Define {
  my ($hash, $def) = @_;
  my @a = split('[ \t]+', $def);
  return 'Syntax: define <name> DEXCOM' if (@a != 2);

  $hash->{VERSION} = '2026-10-10e';
  delete $hash->{helper}{sessionId};
  delete $hash->{helper}{accountId};
  $hash->{helper}{authBlocked} = 0;

  readingsSingleUpdate($hash, 'state', 'Zugangsdaten fehlen', 1)
    if (!DEXCOM_getCredential($hash, 'username'));

  RemoveInternalTimer($hash);
  InternalTimer(gettimeofday() + 15, 'DEXCOM_Poll', $hash) if ($init_done);
  InternalTimer(gettimeofday() + 30, 'DEXCOM_Poll', $hash) if (!$init_done);
  return;
}

sub DEXCOM_Undef {
  my ($hash) = @_;
  RemoveInternalTimer($hash);
  HttpUtils_Close($hash->{helper}{http}) if ($hash->{helper}{http});
  return;
}

sub DEXCOM_Delete {
  my ($hash, $name) = @_;
  setKeyValue("DEXCOM_${name}_username", undef);
  setKeyValue("DEXCOM_${name}_password", undef);
  return;
}

sub DEXCOM_Rename {
  my ($new, $old) = @_;
  for my $k (qw(username password)) {
    my (undef, $v) = getKeyValue("DEXCOM_${old}_$k");
    setKeyValue("DEXCOM_${new}_$k", $v);
    setKeyValue("DEXCOM_${old}_$k", undef);
  }
  return;
}

sub DEXCOM_Attr {
  my ($cmd, $name, $attr, $val) = @_;
  my $hash = $defs{$name};
  if ($attr eq 'interval' && $cmd eq 'set') {
    return 'interval muss eine Zahl >= 60 (Sekunden) sein' if ($val !~ /^\d+$/ || $val < 60);
  }
  if ($attr =~ /^(range(Low|High)|hypoLimit)$/ && $cmd eq 'set') {
    return "$attr muss ein Glukosewert in mg/dL sein" if ($val !~ /^\d+$/ || $val < 20 || $val > 600);
  }
  if ($attr eq 'region') {
    delete $hash->{helper}{sessionId};
    delete $hash->{helper}{accountId};
  }
  if ($attr eq 'disable') {
    RemoveInternalTimer($hash);
    if ($cmd eq 'set' && $val) {
      readingsSingleUpdate($hash, 'state', 'deaktiviert', 1);
    } else {
      InternalTimer(gettimeofday() + 2, 'DEXCOM_Poll', $hash);
    }
  }
  return;
}

sub DEXCOM_Set {
  my ($hash, $name, $cmd, @args) = @_;
  return "Unknown argument $cmd, choose one of account update:noArg relogin:noArg"
    if (!$cmd || $cmd eq '?');

  if ($cmd eq 'account') {
    return 'Syntax: set <name> account <Benutzername> <Passwort>' if (@args != 2);
    DEXCOM_setCredential($hash, 'username', $args[0]);
    DEXCOM_setCredential($hash, 'password', $args[1]);
    delete $hash->{helper}{sessionId};
    delete $hash->{helper}{accountId};
    $hash->{helper}{authBlocked} = 0;
    readingsSingleUpdate($hash, 'lastError', 'none', 0);
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday() + 1, 'DEXCOM_Poll', $hash);
    return;
  }
  if ($cmd eq 'relogin') {
    delete $hash->{helper}{sessionId};
    delete $hash->{helper}{accountId};
    $hash->{helper}{authBlocked} = 0;
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday() + 1, 'DEXCOM_Poll', $hash);
    return;
  }
  if ($cmd eq 'update') {
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday() + 1, 'DEXCOM_Poll', $hash);
    return;
  }
  return "Unknown argument $cmd, choose one of account update:noArg relogin:noArg";
}

########################################
# Zugangsdaten verschleiert im FHEM-Schluesselspeicher (nicht in fhem.cfg)

sub DEXCOM_setCredential {
  my ($hash, $what, $value) = @_;
  my $key = getUniqueId() . $hash->{NAME};
  my $enc = '';
  for my $char (split //, $value) {
    my $encode = chop($key);
    $enc .= sprintf('%.2x', ord($char) ^ ord($encode));
    $key = $encode . $key;
  }
  setKeyValue("DEXCOM_$hash->{NAME}_$what", $enc);
  return;
}

sub DEXCOM_getCredential {
  my ($hash, $what) = @_;
  my ($err, $enc) = getKeyValue("DEXCOM_$hash->{NAME}_$what");
  return if ($err || !defined($enc) || $enc eq '');
  my $key = getUniqueId() . $hash->{NAME};
  my $dec = '';
  for my $char (map { pack('C', hex($_)) } ($enc =~ /(..)/g)) {
    my $decode = chop($key);
    $dec .= chr(ord($char) ^ ord($decode));
    $key = $decode . $key;
  }
  return $dec;
}

########################################
# Abfragezyklus

sub DEXCOM_Poll {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  RemoveInternalTimer($hash);
  return if (IsDisabled($name));

  my $interval = AttrVal($name, 'interval', 300);
  InternalTimer(gettimeofday() + $interval, 'DEXCOM_Poll', $hash);

  if ($hash->{helper}{authBlocked}) {
    Log3 $name, 4, "$name: Anmeldung gesperrt bis 'set $name account ...'";
    return;
  }
  if (!DEXCOM_getCredential($hash, 'username') || !DEXCOM_getCredential($hash, 'password')) {
    readingsSingleUpdate($hash, 'state', 'Zugangsdaten fehlen', 1);
    return;
  }

  $hash->{helper}{retried} = 0;
  return DEXCOM_ReadGlucose($hash) if ($hash->{helper}{sessionId});
  return DEXCOM_Login($hash);
}

sub DEXCOM_Login {
  my ($hash) = @_;
  my $region = AttrVal($hash->{NAME}, 'region', 'ous');
  my $pw = DEXCOM_getCredential($hash, 'password');

  if (!$hash->{helper}{accountId}) {
    return DEXCOM_Request($hash, 'General/AuthenticatePublisherAccount', undef,
      { accountName => DEXCOM_getCredential($hash, 'username'),
        password => $pw, applicationId => $DEXCOM_appId{$region} },
      \&DEXCOM_ParseAccountId);
  }
  return DEXCOM_Request($hash, 'General/LoginPublisherAccountById', undef,
    { accountId => $hash->{helper}{accountId},
      password => $pw, applicationId => $DEXCOM_appId{$region} },
    \&DEXCOM_ParseSessionId);
}

sub DEXCOM_ReadGlucose {
  my ($hash) = @_;
  return DEXCOM_Request($hash, 'Publisher/ReadPublisherLatestGlucoseValues',
    "sessionId=$hash->{helper}{sessionId}&minutes=1440&maxCount=288", {},
    \&DEXCOM_ParseGlucose);
}

sub DEXCOM_Request {
  my ($hash, $endpoint, $query, $body, $handler) = @_;
  my $region = AttrVal($hash->{NAME}, 'region', 'ous');
  my $url = $DEXCOM_baseUrl{$region} . $endpoint . (defined($query) ? "?$query" : '');
  Log3 $hash->{NAME}, 5, "$hash->{NAME}: POST $endpoint";
  $hash->{helper}{http} = {
    url        => $url,
    method     => 'POST',
    timeout    => 20,
    hash       => $hash,
    header     => "Content-Type: application/json\r\nAccept: application/json",
    data       => encode_json($body),
    handler    => $handler,
    callback   => \&DEXCOM_Callback,
  };
  HttpUtils_NonblockingGet($hash->{helper}{http});
  return;
}

sub DEXCOM_Callback {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  if ($err) {
    return DEXCOM_Error($hash, "Verbindungsfehler: $err");
  }
  my $json = eval { JSON->new->allow_nonref->decode($data // '') };
  if (!defined($json)) {
    return DEXCOM_Error($hash, "Ungueltige Antwort (HTTP $param->{code})");
  }
  if (ref($json) eq 'HASH' && $json->{Code}) {
    my ($code, $msg) = ($json->{Code}, $json->{Message} // '');
    if ($code eq 'SessionIdNotFound' || $code eq 'SessionNotValid') {
      delete $hash->{helper}{sessionId};
      if (!$hash->{helper}{retried}++) {
        Log3 $name, 4, "$name: Sitzung abgelaufen, melde neu an";
        return DEXCOM_Login($hash);
      }
      return DEXCOM_Error($hash, "Sitzung ungueltig: $code");
    }
    if ($DEXCOM_authFatal{$code}
        || ($code eq 'SSO_InternalError' && $msg =~ /Cannot Authenticate/)
        || ($code eq 'InvalidArgument' && $msg =~ /accountName|password|UUID/)) {
      return DEXCOM_AuthFailed($hash, "$code: $msg");
    }
    return DEXCOM_Error($hash, "$code: $msg");
  }
  return $param->{handler}->($hash, $json);
}

sub DEXCOM_ParseAccountId {
  my ($hash, $json) = @_;
  if (ref($json) || !$json || $json eq $DEXCOM_defaultUuid) {
    return DEXCOM_AuthFailed($hash, 'Konto nicht gefunden (Benutzername pruefen)');
  }
  $hash->{helper}{accountId} = $json;
  return DEXCOM_Login($hash);
}

sub DEXCOM_ParseSessionId {
  my ($hash, $json) = @_;
  if (ref($json) || !$json || $json eq $DEXCOM_defaultUuid) {
    return DEXCOM_AuthFailed($hash, 'Anmeldung abgelehnt (Passwort pruefen)');
  }
  $hash->{helper}{sessionId} = $json;
  Log3 $hash->{NAME}, 4, "$hash->{NAME}: angemeldet";
  return DEXCOM_ReadGlucose($hash);
}

sub DEXCOM_ParseGlucose {
  my ($hash, $json) = @_;
  my $name = $hash->{NAME};
  if (ref($json) ne 'ARRAY') {
    return DEXCOM_Error($hash, 'Unerwartete Antwort beim Lesen der Werte');
  }
  if (!@$json) {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'state', 'keine Werte (24h)');
    readingsBulkUpdateIfChanged($hash, 'lastError', 'none');
    readingsEndUpdate($hash, 1);
    return;
  }

  # Alle Messwerte der letzten 24 h: [epoch, Wert, Trend], neueste zuerst
  my @vals;
  for my $e (@$json) {
    my ($ems) = (($e->{WT} // $e->{DT} // '') =~ /Date\((\d+)/);
    next if (!$ems || !defined($e->{Value}) || $e->{Value} !~ /^\d+$/);
    push @vals, [ int($ems / 1000), $e->{Value}, $e->{Trend} ];
  }
  @vals = sort { $b->[0] <=> $a->[0] } @vals;
  return DEXCOM_Error($hash, 'Glukosewert unvollstaendig') if (!@vals);

  my ($epoch, $value, $trend) = @{ $vals[0] };
  my $time = FmtDateTime($epoch);

  $trend //= 'None';
  my ($t) = $trend =~ /^\d+$/ ? ($DEXCOM_trends[$trend]) : grep { $_->[0] eq $trend } @DEXCOM_trends;
  $t //= [ $trend, '', $trend ];

  # Reading aus Version 1, ersetzt durch "trend"
  readingsDelete($hash, 'trend_description') if (exists($hash->{READINGS}{trend_description}));

  readingsBeginUpdate($hash);
  if ($time ne ReadingsVal($name, 'glucose_time', '')
      || ReadingsVal($name, 'trend', '') ne $t->[2]) {
    # Neue Messung: alle Werte aktualisieren (erzeugt Events)
    readingsBulkUpdate($hash, 'glucose', $value);
    readingsBulkUpdate($hash, 'glucose_mmol', sprintf('%.1f', $value * 0.0555));
    readingsBulkUpdate($hash, 'trend', $t->[2]);
    readingsBulkUpdate($hash, 'trend_arrow', $t->[1]);
    readingsBulkUpdate($hash, 'trend_code', $t->[0]);
    readingsBulkUpdate($hash, 'glucose_time', $time);
  }
  readingsBulkUpdate($hash, 'glucose_age', int((time() - $epoch) / 60));
  readingsBulkUpdate($hash, 'state', $value);
  readingsBulkUpdateIfChanged($hash, 'lastError', 'none');
  DEXCOM_Statistics($hash, \@vals);
  DEXCOM_HypoEpisodes($hash, \@vals);
  readingsEndUpdate($hash, 1);
  return;
}

########################################
# Tagesauswertung aus den Sensorwerten der letzten 24 h (ersetzt die
# userReadings/at-Berechnungen am MQTT-Geraet; gleiche Formeln):
#   glucose_max_today / glucose_min_today  hoechster/niedrigster Wert heute
#   glucose_avg_today                      Durchschnitt heute (ganzzahlig)
#   glucose_in_range_percent               Anteil heute in [rangeLow, rangeHigh]
#   glucose_avg_yesterday                  Tagesdurchschnitt gestern (beim Tageswechsel)
#   glucose_avg_history                    Tagesdurchschnitte "JJJJ-MM-TT:Wert,..." (14 Tage)
#   glucose_GMI_14_days                    GMI = 3.31 + 0.02392 * Mittel der Tagesdurchschnitte

sub DEXCOM_Statistics {
  my ($hash, $vals) = @_;
  my $name  = $hash->{NAME};
  my $low   = AttrVal($name, 'rangeLow', 80);
  my $high  = AttrVal($name, 'rangeHigh', 180);
  my $today = strftime('%Y-%m-%d', localtime());
  my $yday  = strftime('%Y-%m-%d', localtime(time() - 86400));

  my (@t, @y);
  for my $v (@$vals) {
    my $d = strftime('%Y-%m-%d', localtime($v->[0]));
    push @t, $v->[1] if ($d eq $today);
    push @y, $v->[1] if ($d eq $yday);
  }

  if (@t) {
    my ($min, $max, $sum, $in) = (9999, 0, 0, 0);
    for (@t) {
      $min = $_ if ($_ < $min);
      $max = $_ if ($_ > $max);
      $sum += $_;
      $in++ if ($_ >= $low && $_ <= $high);
    }
    readingsBulkUpdateIfChanged($hash, 'glucose_max_today', $max);
    readingsBulkUpdateIfChanged($hash, 'glucose_min_today', $min);
    readingsBulkUpdateIfChanged($hash, 'glucose_avg_today', int($sum / @t));
    readingsBulkUpdateIfChanged($hash, 'glucose_in_range_percent', int($in / @t * 100));
  }

  # Tageswechsel: Durchschnitt von gestern einmalig in die Historie uebernehmen.
  # Die 24-h-Daten decken gestern nur ab dem Zeitpunkt "jetzt minus 24 h" ab -
  # beim ersten Abruf nach Mitternacht also praktisch den ganzen Tag.
  my %hist = map { split(/:/, $_, 2) } grep { /^\d{4}-\d\d-\d\d:\d+$/ }
             split(/,/, ReadingsVal($name, 'glucose_avg_history', ''));
  if (@y && !exists($hist{$yday})) {
    my $sum = 0;
    $sum += $_ for (@y);
    $hist{$yday} = int($sum / @y);
    readingsBulkUpdate($hash, 'glucose_avg_yesterday', $hist{$yday});
    Log3 $name, 4, "$name: Tagesdurchschnitt $yday = $hist{$yday} (" . scalar(@y) . ' Werte)';
  }

  # nur die 14 Tage vor heute behalten (wie bisher: Tage 1..14 zurueck)
  my $oldest = strftime('%Y-%m-%d', localtime(time() - 14 * 86400));
  my @days = grep { $_ ge $oldest && $_ lt $today } sort { $b cmp $a } keys %hist;
  readingsBulkUpdateIfChanged($hash, 'glucose_avg_history', join(',', map { "$_:$hist{$_}" } @days));

  if (@days) {
    my $sum = 0;
    $sum += $hist{$_} for (@days);
    readingsBulkUpdateIfChanged($hash, 'glucose_GMI_14_days', sprintf('%.2f', 3.31 + 0.02392 * $sum / @days));
  }
  return;
}

########################################
# Unterzuckerungs-Episoden nach internationalem CGM-Konsensus:
#   Beginn: mind. 15 Minuten durchgehend < hypoLimit (mind. 3 Messwerte in Folge)
#   Ende:   mind. 15 Minuten durchgehend >= hypoLimit (Ende = erster Wert darueber)
# Eine Messluecke > 15 Minuten unterbricht die Folge (laufende Episode endet
# mit dem letzten Wert vor der Luecke).
#   hypo_episodes_today / hypo_minutes_today   heute begonnene Episoden
#   hypo_active                                ja/nein
#   last_hypo / last_hypo_duration / last_hypo_lowest   letzte Episode (bleibt stehen)

sub DEXCOM_HypoEpisodes {
  my ($hash, $vals) = @_;
  my $name  = $hash->{NAME};
  my $limit = AttrVal($name, 'hypoLimit', 70);
  my $gap   = 15 * 60;
  my @asc   = reverse @$vals;        # aelteste zuerst

  my (@eps, $ep, @below, $aboveStart, $aboveCount, $prevT);
  my $close = sub { my ($end) = @_; $ep->{end} = $end; push @eps, $ep; undef $ep; };

  for my $v (@asc) {
    my ($t, $val) = @$v;
    if (defined($prevT) && $t - $prevT > $gap) {
      $close->($prevT + 300) if ($ep);  # Luecke beendet die Episode
      @below = ();
      ($aboveStart, $aboveCount) = (undef, 0);
    }
    $prevT = $t;

    if ($val < $limit) {
      ($aboveStart, $aboveCount) = (undef, 0);
      if ($ep) {
        $ep->{min} = $val if ($val < $ep->{min});
      } else {
        push @below, $v;
        if (@below >= 3) {
          my $min = $limit;
          for (@below) { $min = $_->[1] if ($_->[1] < $min) }
          $ep = { start => $below[0][0], min => $min };
          @below = ();
        }
      }
    } else {
      @below = ();
      next if (!$ep);
      $aboveStart //= $t;
      $close->($aboveStart) if (++$aboveCount >= 3);
    }
  }
  push @eps, $ep if ($ep);             # noch laufende Episode (ohne Ende)

  my $today = strftime('%Y-%m-%d', localtime());
  my $now   = $asc[-1][0];
  my ($count, $minutes) = (0, 0);
  for my $e (@eps) {
    next if (strftime('%Y-%m-%d', localtime($e->{start})) ne $today);
    $count++;
    $minutes += int((($e->{end} // $now + 300) - $e->{start}) / 60);
  }
  readingsBulkUpdateIfChanged($hash, 'hypo_episodes_today', $count);
  readingsBulkUpdateIfChanged($hash, 'hypo_minutes_today', $minutes);
  readingsBulkUpdateIfChanged($hash, 'hypo_active', (@eps && !defined($eps[-1]{end})) ? 'ja' : 'nein');

  if (@eps) {
    my $last = $eps[-1];
    readingsBulkUpdateIfChanged($hash, 'last_hypo', FmtDateTime($last->{start}));
    readingsBulkUpdateIfChanged($hash, 'last_hypo_duration',
      int((($last->{end} // $now + 300) - $last->{start}) / 60));
    readingsBulkUpdateIfChanged($hash, 'last_hypo_lowest', $last->{min});
  }
  return;
}

sub DEXCOM_Error {
  my ($hash, $msg) = @_;
  Log3 $hash->{NAME}, 3, "$hash->{NAME}: $msg";
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, 'lastError', $msg);
  readingsBulkUpdate($hash, 'state', 'Fehler');
  readingsEndUpdate($hash, 1);
  return;
}

sub DEXCOM_AuthFailed {
  my ($hash, $msg) = @_;
  my $name = $hash->{NAME};
  $hash->{helper}{authBlocked} = 1;
  delete $hash->{helper}{sessionId};
  delete $hash->{helper}{accountId};
  Log3 $name, 1, "$name: $msg - keine weiteren Anmeldeversuche bis 'set $name account ...' (Schutz vor Kontosperre)";
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, 'lastError', $msg);
  readingsBulkUpdate($hash, 'state', 'Anmeldung fehlgeschlagen');
  readingsEndUpdate($hash, 1);
  return;
}

1;

=pod
=item device
=item summary Dexcom Share CGM: glucose, trend, daily statistics, GMI, hypo episodes
=item summary_DE Dexcom-Share CGM: Glukose, Trend, Tagesstatistik, GMI, Unterzuckerungen

=begin html

<a id="DEXCOM"></a>
<h3>DEXCOM</h3>
<ul>
  Reads the current glucose value of a Dexcom CGM (continuous glucose monitor) together with
  its trend from the Dexcom Share service and derives daily statistics, a 14-day GMI and
  hypoglycaemia episodes from the sensor values of the last 24 hours.<br>
  It uses the same (unofficial) Share interface as the Dexcom Follow app and the Home Assistant
  integration (pydexcom). Data is current to within the sensor's 5-minute cycle.<br><br>

  <b>Not a medical device.</b> All values are for information only. For therapy decisions and
  alarms the Dexcom app and its alerts are authoritative.<br><br>

  <b>Prerequisites</b>
  <ul>
    <li>Share must be enabled in the Dexcom app (with at least one follower).</li>
    <li>The credentials must be those of the account that <b>shares</b>, i.e. the person
        wearing the sensor. A follower account can log in, but has no glucose values of its
        own (the device then shows <code>keine Werte (24h)</code>).</li>
    <li>Perl modules JSON and HttpUtils (part of FHEM).</li>
  </ul>
  <br>

  <a id="DEXCOM-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; DEXCOM</code><br><br>
    Example:
    <pre>
define Dexcom DEXCOM
attr Dexcom room Gesundheit
set Dexcom account max.mustermann@example.com MySecret</pre>
  </ul>

  <a id="DEXCOM-set"></a>
  <b>Set</b>
  <ul>
    <a id="DEXCOM-set-account"></a>
    <li><code>set &lt;name&gt; account &lt;username&gt; &lt;password&gt;</code><br>
      Stores the Dexcom account and starts polling. Username and password are kept
      obfuscated in FHEM's key store (FhemUtils/uniqueID), not in fhem.cfg.
      The username is what you use to log in to the Dexcom app (e-mail address, user name,
      or phone number with country code, e.g. +49170...).<br>
      Note for the FHEM command line: a <code>;</code> in the password must be written as <code>;;</code>.
      Passwords containing spaces are not supported.</li>
    <a id="DEXCOM-set-update"></a>
    <li><code>set &lt;name&gt; update</code><br>
      Polls immediately instead of waiting for the next interval.</li>
    <a id="DEXCOM-set-relogin"></a>
    <li><code>set &lt;name&gt; relogin</code><br>
      Drops the current Dexcom session and logs in again. Also lifts the login block
      after a rejected login (see below) without re-entering the credentials.</li>
  </ul>
  <br>

  <a id="DEXCOM-attr"></a>
  <b>Attributes</b>
  <ul>
    <a id="DEXCOM-attr-region"></a>
    <li><code>region</code> ous | us | jp &ndash; Dexcom server. Default <code>ous</code>
      (outside US, correct for accounts in Europe). Corresponds to "server: EU/OUS/US" in Home Assistant.</li>
    <a id="DEXCOM-attr-interval"></a>
    <li><code>interval</code> &ndash; polling interval in seconds, default 300, minimum 60.
      The sensor delivers a new value every 5 minutes, so shorter intervals rarely help.</li>
    <a id="DEXCOM-attr-rangeLow"></a>
    <li><code>rangeLow</code>, <code>rangeHigh</code> &ndash; target range in mg/dL for
      <code>glucose_in_range_percent</code>, default 80 and 180 (both inclusive).</li>
    <a id="DEXCOM-attr-hypoLimit"></a>
    <li><code>hypoLimit</code> &ndash; limit in mg/dL for hypoglycaemia episodes, default 70.
      A value equal to the limit does not count as below.</li>
    <a id="DEXCOM-attr-disable"></a>
    <li><code>disable</code> 0 | 1 &ndash; stops polling.</li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
  <br>

  <a id="DEXCOM-readings"></a>
  <b>Readings</b>
  <ul>
    <b>Current value</b> (updated with every new sensor value)
    <ul>
      <li><code>state</code>, <code>glucose</code> &ndash; glucose in mg/dL</li>
      <li><code>glucose_mmol</code> &ndash; glucose in mmol/L</li>
      <li><code>glucose_time</code> &ndash; time of the measurement according to the sensor</li>
      <li><code>glucose_age</code> &ndash; age of the value in minutes. Values above about 15
        mean that no new data arrives (signal loss, sensor warm-up, phone offline).</li>
      <li><code>trend</code>, <code>trend_arrow</code>, <code>trend_code</code> &ndash; trend as German text, arrow and Dexcom code:
        <table>
          <tr><td>stark steigend</td><td>&uarr;&uarr;</td><td>DoubleUp</td></tr>
          <tr><td>steigend</td><td>&uarr;</td><td>SingleUp</td></tr>
          <tr><td>leicht steigend</td><td>&nearr;</td><td>FortyFiveUp</td></tr>
          <tr><td>stabil</td><td>&rarr;</td><td>Flat</td></tr>
          <tr><td>leicht fallend</td><td>&searr;</td><td>FortyFiveDown</td></tr>
          <tr><td>fallend</td><td>&darr;</td><td>SingleDown</td></tr>
          <tr><td>stark fallend</td><td>&darr;&darr;</td><td>DoubleDown</td></tr>
          <tr><td>unbestimmt</td><td>?</td><td>NotComputable</td></tr>
          <tr><td>nicht verf&uuml;gbar</td><td>-</td><td>RateOutOfRange</td></tr>
        </table></li>
    </ul>
    <b>Today</b> (calendar day, computed from all sensor values of today)
    <ul>
      <li><code>glucose_max_today</code>, <code>glucose_min_today</code>, <code>glucose_avg_today</code></li>
      <li><code>glucose_in_range_percent</code> &ndash; share of today's values within rangeLow..rangeHigh</li>
    </ul>
    <b>History and GMI</b>
    <ul>
      <li><code>glucose_avg_yesterday</code> &ndash; average of the previous day, taken once on the first poll after midnight</li>
      <li><code>glucose_avg_history</code> &ndash; daily averages of the 14 days before today,
        format <code>YYYY-MM-DD:value,...</code>, newest first</li>
      <li><code>glucose_GMI_14_days</code> &ndash; Glucose Management Indicator in %:
        3.31 + 0.02392 &times; mean of the daily averages in glucose_avg_history</li>
    </ul>
    <b>Hypoglycaemia episodes</b> (international CGM consensus definition)
    <ul>
      An episode starts after at least 15 minutes (3 consecutive values) below hypoLimit and
      ends only after at least 15 minutes at or above it, so a short rise in between does not
      split it. A data gap of more than 15 minutes ends a running episode.
      <li><code>hypo_episodes_today</code>, <code>hypo_minutes_today</code> &ndash; episodes that started today and their total duration</li>
      <li><code>hypo_active</code> &ndash; ja | nein</li>
      <li><code>last_hypo</code>, <code>last_hypo_duration</code>, <code>last_hypo_lowest</code> &ndash;
        start, duration (minutes) and lowest value of the most recent episode. Kept until the next episode.</li>
    </ul>
    <b>Status</b>
    <ul>
      <li><code>lastError</code> &ndash; last error, or <code>none</code></li>
    </ul>
  </ul>
  <br>

  <b>How it works</b>
  <ul>
    <li>Login: AuthenticatePublisherAccount (account ID), then LoginPublisherAccountById (session ID).
      An expired session is renewed automatically.</li>
    <li>Every interval: ReadPublisherLatestGlucoseValues for the last 24 hours (up to 288 values).
      The newest value fills the current readings, all values feed the statistics, so restarts
      of FHEM or gaps do not distort the daily figures.</li>
    <li><b>Login protection:</b> after a rejected login (wrong password, unknown account, too many
      attempts) the module does <b>not</b> retry, because Dexcom locks the account after several
      failures, which would also affect the Dexcom app. Fix the credentials and use
      <code>set account</code> again (or <code>set relogin</code>).</li>
  </ul>
  <br>

  <b>Tips</b>
  <ul>
    <li>Show value and arrow in the device overview: <code>attr Dexcom stateFormat glucose trend_arrow</code></li>
    <li>Seed the GMI with existing daily averages so it is meaningful from day one:<br>
      <code>setreading Dexcom glucose_avg_history 2026-01-15:142,2026-01-14:155,...</code></li>
    <li>Log values: <code>define Log_Dexcom FileLog ./log/Dexcom-%Y-%m.log Dexcom:glucose:.*|Dexcom:trend:.*</code></li>
  </ul>
  <br>

  <b>Troubleshooting</b>
  <ul>
    <li><code>Zugangsdaten fehlen</code> &ndash; no account stored yet: <code>set account</code>.</li>
    <li><code>Anmeldung fehlgeschlagen</code> with lastError <code>AccountPasswordInvalid</code> &ndash;
      username or password wrong (check <code>;;</code>), or wrong region.</li>
    <li><code>keine Werte (24h)</code> &ndash; login works but there are no values: follower
      account instead of the sharing account, wrong region, or no sensor data in the last 24 hours.</li>
    <li><code>Fehler</code> &ndash; see lastError (network, server). Polling continues normally.</li>
    <li>More detail in the FHEM log with <code>attr Dexcom verbose 4</code> (5 also logs every request).</li>
  </ul>
</ul>

=end html

=begin html_DE

<a id="DEXCOM"></a>
<h3>DEXCOM</h3>
<ul>
  Liest den aktuellen Glukosewert eines Dexcom-CGM (kontinuierliche Glukosemessung) samt Trend
  aus dem Dexcom-Share-Dienst und berechnet aus den Sensorwerten der letzten 24 Stunden eine
  Tagesstatistik, den GMI &uuml;ber 14 Tage und Unterzuckerungs-Episoden.<br>
  Genutzt wird dieselbe (inoffizielle) Share-Schnittstelle wie von der Dexcom-Follow-App und der
  Home-Assistant-Integration (pydexcom). Die Daten sind so aktuell wie der 5-Minuten-Takt des Sensors.<br><br>

  <b>Kein Medizinprodukt.</b> Alle Werte dienen nur der Information. F&uuml;r Therapieentscheidungen
  und Alarme sind ausschlie&szlig;lich die Dexcom-App und ihre Warnungen ma&szlig;geblich.<br><br>

  <b>Voraussetzungen</b>
  <ul>
    <li>In der Dexcom-App muss Share aktiviert sein (mit mindestens einem Follower).</li>
    <li>Die Zugangsdaten m&uuml;ssen die des Kontos sein, das <b>teilt</b>, also der Person, die den
        Sensor tr&auml;gt. Ein Follower-Konto kann sich zwar anmelden, hat aber keine eigenen Werte
        (das Ger&auml;t zeigt dann <code>keine Werte (24h)</code>).</li>
    <li>Perl-Module JSON und HttpUtils (Bestandteil von FHEM).</li>
  </ul>
  <br>

  <a id="DEXCOM-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; DEXCOM</code><br><br>
    Beispiel:
    <pre>
define Dexcom DEXCOM
attr Dexcom room Gesundheit
set Dexcom account max.mustermann@example.com MeinPasswort</pre>
  </ul>

  <a id="DEXCOM-set"></a>
  <b>Set</b>
  <ul>
    <a id="DEXCOM-set-account"></a>
    <li><code>set &lt;name&gt; account &lt;Benutzername&gt; &lt;Passwort&gt;</code><br>
      Speichert das Dexcom-Konto und startet die Abfrage. Benutzername und Passwort liegen verschleiert
      im FHEM-Schl&uuml;sselspeicher (FhemUtils/uniqueID), nicht in der fhem.cfg.
      Benutzername ist das, womit man sich in der Dexcom-App anmeldet (E-Mail-Adresse, Benutzername
      oder Telefonnummer mit L&auml;ndervorwahl, z.&nbsp;B. +49170...).<br>
      Hinweis f&uuml;r die FHEM-Befehlszeile: Ein <code>;</code> im Passwort muss als <code>;;</code>
      geschrieben werden. Passw&ouml;rter mit Leerzeichen werden nicht unterst&uuml;tzt.</li>
    <a id="DEXCOM-set-update"></a>
    <li><code>set &lt;name&gt; update</code><br>
      Fragt sofort ab, statt auf das n&auml;chste Intervall zu warten.</li>
    <a id="DEXCOM-set-relogin"></a>
    <li><code>set &lt;name&gt; relogin</code><br>
      Verwirft die aktuelle Dexcom-Sitzung und meldet neu an. Hebt au&szlig;erdem die Anmeldesperre nach
      einer abgelehnten Anmeldung auf (siehe unten), ohne die Zugangsdaten neu einzugeben.</li>
  </ul>
  <br>

  <a id="DEXCOM-attr"></a>
  <b>Attribute</b>
  <ul>
    <a id="DEXCOM-attr-region"></a>
    <li><code>region</code> ous | us | jp &ndash; Dexcom-Server. Standard <code>ous</code> (au&szlig;erhalb der USA,
      richtig f&uuml;r Konten in Europa). Entspricht &bdquo;server: EU/OUS/US&ldquo; in Home Assistant.</li>
    <a id="DEXCOM-attr-interval"></a>
    <li><code>interval</code> &ndash; Abfrageintervall in Sekunden, Standard 300, mindestens 60.
      Der Sensor liefert alle 5 Minuten einen neuen Wert, k&uuml;rzere Intervalle bringen also selten etwas.</li>
    <a id="DEXCOM-attr-rangeLow"></a>
    <li><code>rangeLow</code>, <code>rangeHigh</code> &ndash; Zielbereich in mg/dL f&uuml;r
      <code>glucose_in_range_percent</code>, Standard 80 und 180 (jeweils einschlie&szlig;lich).</li>
    <a id="DEXCOM-attr-hypoLimit"></a>
    <li><code>hypoLimit</code> &ndash; Grenze in mg/dL f&uuml;r Unterzuckerungs-Episoden, Standard 70.
      Ein Wert genau auf der Grenze z&auml;hlt nicht als darunter.</li>
    <a id="DEXCOM-attr-disable"></a>
    <li><code>disable</code> 0 | 1 &ndash; stoppt die Abfrage.</li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
  <br>

  <a id="DEXCOM-readings"></a>
  <b>Readings</b>
  <ul>
    <b>Aktueller Wert</b> (bei jedem neuen Sensorwert aktualisiert)
    <ul>
      <li><code>state</code>, <code>glucose</code> &ndash; Glukosewert in mg/dL</li>
      <li><code>glucose_mmol</code> &ndash; Glukosewert in mmol/L</li>
      <li><code>glucose_time</code> &ndash; Zeitpunkt der Messung laut Sensor</li>
      <li><code>glucose_age</code> &ndash; Alter des Werts in Minuten. Werte &uuml;ber etwa 15 bedeuten,
        dass keine neuen Daten ankommen (Funkabriss, Aufw&auml;rmphase des Sensors, Handy offline).</li>
      <li><code>trend</code>, <code>trend_arrow</code>, <code>trend_code</code> &ndash; Trend als Text, Pfeil und Dexcom-Code:
        <table>
          <tr><td>stark steigend</td><td>&uarr;&uarr;</td><td>DoubleUp</td></tr>
          <tr><td>steigend</td><td>&uarr;</td><td>SingleUp</td></tr>
          <tr><td>leicht steigend</td><td>&nearr;</td><td>FortyFiveUp</td></tr>
          <tr><td>stabil</td><td>&rarr;</td><td>Flat</td></tr>
          <tr><td>leicht fallend</td><td>&searr;</td><td>FortyFiveDown</td></tr>
          <tr><td>fallend</td><td>&darr;</td><td>SingleDown</td></tr>
          <tr><td>stark fallend</td><td>&darr;&darr;</td><td>DoubleDown</td></tr>
          <tr><td>unbestimmt</td><td>?</td><td>NotComputable</td></tr>
          <tr><td>nicht verf&uuml;gbar</td><td>-</td><td>RateOutOfRange</td></tr>
        </table></li>
    </ul>
    <b>Heute</b> (Kalendertag, berechnet aus allen Sensorwerten von heute)
    <ul>
      <li><code>glucose_max_today</code>, <code>glucose_min_today</code>, <code>glucose_avg_today</code></li>
      <li><code>glucose_in_range_percent</code> &ndash; Anteil der heutigen Werte zwischen rangeLow und rangeHigh</li>
    </ul>
    <b>Verlauf und GMI</b>
    <ul>
      <li><code>glucose_avg_yesterday</code> &ndash; Durchschnitt des Vortags, einmalig beim ersten Abruf nach Mitternacht festgehalten</li>
      <li><code>glucose_avg_history</code> &ndash; Tagesdurchschnitte der 14 Tage vor heute,
        Format <code>JJJJ-MM-TT:Wert,...</code>, neuester zuerst</li>
      <li><code>glucose_GMI_14_days</code> &ndash; Glucose Management Indicator in %:
        3,31 + 0,02392 &times; Mittel der Tagesdurchschnitte aus glucose_avg_history</li>
    </ul>
    <b>Unterzuckerungs-Episoden</b> (Definition nach internationalem CGM-Konsensus)
    <ul>
      Eine Episode beginnt nach mindestens 15 Minuten (3 Werte in Folge) unter hypoLimit und endet
      erst nach mindestens 15 Minuten bei oder &uuml;ber der Grenze. Ein kurzes Hoch zwischendrin teilt
      sie also nicht. Eine Messl&uuml;cke von mehr als 15 Minuten beendet eine laufende Episode.
      <li><code>hypo_episodes_today</code>, <code>hypo_minutes_today</code> &ndash; heute begonnene Episoden und ihre Gesamtdauer</li>
      <li><code>hypo_active</code> &ndash; ja | nein</li>
      <li><code>last_hypo</code>, <code>last_hypo_duration</code>, <code>last_hypo_lowest</code> &ndash;
        Beginn, Dauer (Minuten) und tiefster Wert der letzten Episode. Bleiben bis zur n&auml;chsten Episode stehen.</li>
    </ul>
    <b>Status</b>
    <ul>
      <li><code>lastError</code> &ndash; letzter Fehler oder <code>none</code></li>
    </ul>
  </ul>
  <br>

  <b>Funktionsweise</b>
  <ul>
    <li>Anmeldung: AuthenticatePublisherAccount (Konto-ID), dann LoginPublisherAccountById (Sitzungs-ID).
      Eine abgelaufene Sitzung wird automatisch erneuert.</li>
    <li>In jedem Intervall: ReadPublisherLatestGlucoseValues f&uuml;r die letzten 24 Stunden (bis zu 288 Werte).
      Der neueste Wert f&uuml;llt die aktuellen Readings, alle Werte flie&szlig;en in die Statistik. Neustarts von FHEM
      oder L&uuml;cken verf&auml;lschen die Tageszahlen deshalb nicht.</li>
    <li><b>Anmeldeschutz:</b> Nach einer abgelehnten Anmeldung (falsches Passwort, unbekanntes Konto,
      zu viele Versuche) versucht das Modul es <b>nicht</b> erneut, denn Dexcom sperrt das Konto nach mehreren
      Fehlversuchen, und das w&uuml;rde auch die Dexcom-App treffen. Zugangsdaten korrigieren und
      <code>set account</code> erneut ausf&uuml;hren (oder <code>set relogin</code>).</li>
  </ul>
  <br>

  <b>Tipps</b>
  <ul>
    <li>Wert und Pfeil in der Ger&auml;te&uuml;bersicht: <code>attr Dexcom stateFormat glucose trend_arrow</code></li>
    <li>GMI mit vorhandenen Tagesdurchschnitten vorbelegen, damit er ab dem ersten Tag aussagekr&auml;ftig ist:<br>
      <code>setreading Dexcom glucose_avg_history 2026-01-15:142,2026-01-14:155,...</code></li>
    <li>Werte loggen: <code>define Log_Dexcom FileLog ./log/Dexcom-%Y-%m.log Dexcom:glucose:.*|Dexcom:trend:.*</code></li>
  </ul>
  <br>

  <b>Fehlersuche</b>
  <ul>
    <li><code>Zugangsdaten fehlen</code> &ndash; noch kein Konto hinterlegt: <code>set account</code>.</li>
    <li><code>Anmeldung fehlgeschlagen</code> mit lastError <code>AccountPasswordInvalid</code> &ndash;
      Benutzername oder Passwort falsch (an <code>;;</code> denken) oder falsche Region.</li>
    <li><code>keine Werte (24h)</code> &ndash; Anmeldung klappt, aber es gibt keine Werte: Follower-Konto statt des
      teilenden Kontos, falsche Region, oder in den letzten 24 Stunden keine Sensordaten.</li>
    <li><code>Fehler</code> &ndash; siehe lastError (Netzwerk, Server). Die Abfrage l&auml;uft normal weiter.</li>
    <li>Mehr Details im FHEM-Log mit <code>attr Dexcom verbose 4</code> (5 protokolliert zus&auml;tzlich jede Anfrage).</li>
  </ul>
</ul>

=end html_DE

=cut
