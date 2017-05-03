# $Id: 98_DBPlan.pm 73000 2017-05-02 11:06:00Z jowiemann $
##############################################################################
#
#     98_DBPlan.pm
#
#     Calls the URL: http://reiseauskunft.bahn.de/bin/query.exe/dox?S=departure&Z=destination&start=1&rt=1
#     with the given attributes. 
#     S=departure will be replace with "S=".AttrVal($name, "dbplan_station", undef)
#     Z=destination will be replace with "S=".AttrVal($name, "dbplan_destination", undef)
#     See also the domumentation for external calls
#     Internet-Reiseauskunft der Deutschen Bahn AG
#     Externe Aufrufparameter und RÃƒÂ¼ckgabeparameter an externe Systeme
##############################################################################

use strict;                          
use warnings;                        
use Time::HiRes qw(gettimeofday);    
use HttpUtils;
use HTML::Entities;

use LWP;
use Digest::MD5 qw(md5_hex);

my $note_index;

sub DBPlan_Initialize($) {

    my ($hash) = @_;

    $hash->{DefFn}      = 'DBPlan_Define';
    $hash->{UndefFn}    = 'DBPlan_Undef';
    $hash->{SetFn}      = 'DBPlan_Set';
    $hash->{GetFn}      = 'DBPlan_Get';
    $hash->{AttrFn}     = 'DBPlan_Attr';
    $hash->{ReadFn}     = 'DBPlan_Read';

    $hash->{AttrList} =
          "dbplan_plan_url "
        . "dbplan_table_url "
        . "dbplan_station "
        . "dbplan_destination "
        . "dbplan_via_1 "
        . "dbplan_via_2 "
        . "dbplan_journey_prod:multiple-strict,Alle,ICE-Zuege,Intercity-Eurocityzuege,Interregio-Schnellzuege,Nahverkehr,"
        . "S-Bahnen,Busse,Schiffe,U-Bahnen,Strassenbahnen,Anruf-Sammeltaxi "
        . "dbplan_journey_opt:multiple-strict,Direktverbindung,Direktverbindung+Schlafwagen,Direktverbindung+Liegewagen,Fahrradmitnahme "
        . "dbplan_tariff_class:1,2 "
        . "dbplan_board_type:depart,arrive "
        . "dbplan_time_selection:arrive,depart "
        . "dbplan_delayed_Journey:off,on "
        . "dbplan_travel_date "
        . "dbplan_travel_time "
        . "dbplan_max_Journeys:1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30 "
        . "dbplan_reg_train "
        . "dbplan_addon_options "
        . "dbplan-disable:0,1 "
        . "dbplan-remote-timeout "
        . "dbplan-remote-noshutdown:0,1 "
        . "dbplan-remote-loglevel:0,1,2,3,4,5 "
        . "dbplan-default-char "
        . "dbplan-table-headers "
        . "dbplan-station-file "
        . "dbplan-base-type:plan,table "
        . "dbplan-special-char-decode:none,utf8,latin1(default) "
        . $readingFnAttributes;
}

sub DBPlan_Define($$) {

    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );

    $hash->{version} = '02.05.2017 11:06:00';
    
    return "DBPlan_Define - too few parameters: define <name> DBPlan <interval> [<time offset>]" if( (@a < 3) || (@a > 4));

    my $name 	= $a[0];
    my $inter	= 300;
    my $offset  = 0;

    if(int(@a) == 3) { 
       $inter = int($a[2]); 
       if ($inter < 10 && $inter) {
          return "DBPlan_Define - interval too small, please use something > 10 (sec), default is 300 (sec)";
       }
    }
    elsif(int(@a) == 4) { 
       $inter = int($a[2]); 
       if ($inter < 10 && $inter) {
          return "DBPlan_Define - interval too small, please use something > 10 (sec), default is 300 (sec)";
       }
       $offset = int($a[3]); 
       if ($offset < 0 ) {
          return "DBPlan_Define - time offset too small, please use something > 0 (min), default is 0 (min)";
       }
    }

    $hash->{Interval} = $inter;
    $hash->{Time_Offset} = $offset;

    Log3 $name, 3, "DBPlan_Define ($name) - defined with interval $hash->{Interval} (sec)";

    $hash->{PLAN_URL} = AttrVal($name, "dbplan_plan_url", 'http://reiseauskunft.bahn.de/bin/query.exe/dox?S=departure&Z=destination&start=1&rt=1');
    $hash->{TABLE_URL} = AttrVal($name, "dbplan_table_url", 'http://reiseauskunft.bahn.de/bin/bhftafel.exe/dox?&input=station&start=1&rt=1');
    $hash->{BASE_TYPE} = AttrVal($name, "dbplan-base-type", 'plan');

    Log3 $name, 3, "DBPlan_Define ($name) - defined with base type $hash->{BASE_TYPE}";

    $hash->{helper}{STATION} = AttrVal($name, "dbplan_station", undef);
    $hash->{helper}{DESTINATION} = AttrVal($name, "dbplan_destination", undef);

    # initial request after 2 secs, there timer is set to interval for further update
    my $nt = gettimeofday()+$hash->{Interval};
    $hash->{TRIGGERTIME} = $nt;
    $hash->{TRIGGERTIME_FMT} = FmtDateTime($nt);
    RemoveInternalTimer($hash);

    InternalTimer($nt, "DBPlan_Get_DB_Info", $hash, 0);

    unless(defined($hash->{helper}{STATION}) || (defined($hash->{helper}{DESTINATION}) && $hash->{BASE_TYPE} eq "plan"))
    {
        $hash->{DevState} = 'defined';
        #$hash->{state} = 'defined';
        readingsSingleUpdate($hash, "state", "defined", 1);
        return undef;
    }

#    unless(defined($hash->{helper}{DESTINATION}) && $hash->{BASE_TYPE} eq "plan")
#    {
#        $hash->{DevState} = 'defined';
#        $hash->{state} = 'defined';
#        readingsSingleUpdate($hash, "state", "defined", 1);
#        return undef; 
#    }

    $hash->{DevState} = 'initialized';
    #$hash->{state} = 'initialized';
    readingsSingleUpdate($hash, "state", "initialized", 1);    
    
    return undef;
}

sub DBPlan_Undef($$) {
    my ($hash, $arg) = @_; 
    my $name = $hash->{NAME};

    RemoveInternalTimer($hash);

    Log3 $name, 3, "DBPlan_Undef ($name) - removed";

    return undef;                  
}

sub DBPlan_Get($@) {
    my ($hash, @arguments) = @_;
    my $name = $hash->{NAME};

    return "argument missing" if(int(@arguments) < 2);

    if($arguments[1] eq "searchStation" and int(@arguments) >= 2)
    {
        my $table = "";
        my $head = "Station    Id";
        my $width = 10;
        my $stext = join '.*?', @arguments[2..$#arguments];
        $stext = DBPlan_html2txt($stext);
        
        if($stext ne "") {
          $stext = $stext . ".*?";
        }

        foreach my $stationNames (sort keys %{$hash->{helper}{STATION_NAMES}})
        {
            my $string = $stationNames ." - ".$hash->{helper}{STATION_NAMES}{$stationNames};
            my $test = DBPlan_html2txt($string);
            if($test =~ m/$stext/si) {
              $width = length($string) if(length($string) > $width);
              $table .= $string."\n";
            }
        }
        
        return $head."\n".("-" x $width)."\n".encode_entities($table);
    }
#    elsif($arguments[1] eq "showStations" and exists($hash->{helper}{STATION_NAMES}))
#    {
#        my $table = "";
#        my $head = "Station    Id";
#        my $width = 10;
#
#        foreach my $stationNames (sort keys %{$hash->{helper}{STATION_NAMES}})
#        {
#            my $string = $stationNames ." - ".$hash->{helper}{STATION_NAMES}{$stationNames}; 
#            $width = length($string) if(length($string) > $width);
#            $table .= $string."\n";
#        }
#        
#        return $head."\n".("-" x $width)."\n".encode_entities($table);
#    }
    elsif($arguments[1] eq "PlainText")
    {
        my $table = "";
        my $head = "";
        my $width = 100;

        $hash->{helper}{plain} = 1;

        $table = DBPlan_Get_DB_Plain_Text($hash);

        delete ($hash->{helper}{plain}) if exists($hash->{helper}{plain});

        return $head."\n".("-" x $width)."\n".$table;

    }
    else
    {
        return "unknown argument ".$arguments[1].", choose one of".(exists($hash->{helper}{STATION_NAMES}) ? " searchStation" : "")." PlainText"; 
    }

}

sub DBPlan_Set($@) {

   my ($hash, $name, $cmd, @val) = @_;

   my $list = "interval";
   $list .= " timeOffset";
   $list .= " rereadStationFile:noArg" if(defined(AttrVal($name, "dbplan-station-file", undef)));
   $list .= " rereadDBInfo:noArg" if($hash->{DevState} ne 'disabled' && $hash->{DevState} ne 'defined');
   $list .= " inactiv:noArg" if($hash->{DevState} eq 'active' || $hash->{DevState} eq 'initialized');
   $list .= " activ:noArg" if($hash->{DevState} eq 'inactiv');

   if ($cmd eq 'interval')
   {
      if (int @val == 1 && $val[0] > 10) 
      {
         $hash->{Interval} = $val[0];

         # initial request after 2 secs, there timer is set to interval for further update
         my $nt = gettimeofday()+$hash->{Interval};
         $hash->{TRIGGERTIME} = $nt;
         $hash->{TRIGGERTIME_FMT} = FmtDateTime($nt);
         if($hash->{DevState} eq 'active' || $hash->{DevState} eq 'initialized') {
            RemoveInternalTimer($hash);
            InternalTimer($nt, "DBPlan_Get_DB_Info", $hash, 0);
            Log3 $name, 3, "DBPlan_Set ($name) - restarted with new timer interval $hash->{Interval} (sec)";
         } else {
            Log3 $name, 3, "DBPlan_Set ($name) - new timer interval $hash->{Interval} (sec) will be active when starting/enabling";
         }
		 
         return undef;

      } elsif (int @val == 1 && $val[0] <= 10) {
          Log3 $name, 4, "DBPlan_Set ($name) - interval: $val[0] (sec) to small, continuing with $hash->{Interval} (sec)";
          return "DBPlan_Set - interval too small, please use something > 10, defined is $hash->{Interval} (sec)";
      } else {
          Log3 $name, 4, "DBPlan_Set ($name) - interval: no interval (sec) defined, continuing with $hash->{Interval} (sec)";
          return "DBPlan_Set - no interval (sec) defined, please use something > 10, defined is $hash->{Interval} (sec)";
      }
   } # if interval
   elsif ($cmd eq 'rereadDBInfo')
   {
      DBPlan_Get_DB_Info($hash);

      return undef;
   }
   elsif ($cmd eq 'timeOffset')
   {
      if (int @val == 1 && $val[0] >= 0) 
      {
         $hash->{Time_Offset} = $val[0];

         DBPlan_Get_DB_Info($hash);
         return undef;

      } elsif (int @val == 1 && $val[0] < 0) {
          Log3 $name, 4, "DBPlan_Set ($name) - Time_Offset: $val[0] (min) to small, continuing with $hash->{Time_Offset} (min)";
          return "DBPlan_Set - time offset too small, please use something > 10, defined is $hash->{Time_Offset} (sec)";
      } else {
          Log3 $name, 4, "DBPlan_Set ($name) - Time_Offset: no time offset (min) defined, continuing with $hash->{Time_Offset} (min)";
          return "DBPlan_Set - no time offset (min) defined, please use something > 10, defined is $hash->{Time_Offset} (sec)";
      }
   }
   elsif ($cmd eq 'inactiv')
   {
      $hash->{DevState} = 'inactiv';
      #$hash->{state} = 'inactiv';
      readingsSingleUpdate($hash, "state", "inactiv", 1);

      RemoveInternalTimer($hash);    
      Log3 $name, 3, "DBPlan_Set ($name) - interval timer set to inactiv";

      return undef;

   } # if stop
   elsif ($cmd eq 'activ')
   {
      RemoveInternalTimer($hash);
      InternalTimer(gettimeofday()+2, "DBPlan_Get_DB_Info", $hash, 0) if ($hash->{DevState} eq "inactiv");
      $hash->{DevState}='initialized';
      #$hash->{state}='initialized';
      readingsSingleUpdate($hash, "state", "initialized", 1);

      Log3 $name, 3, "DBPlan_Set ($name) - interval timer started with interval $hash->{Interval} (sec)";

      return undef;

   } # if start
   elsif($cmd eq "rereadStationFile")
   {
      DBPlan_loadStationFile($hash);
      return undef;
   }

   return "DBPlan_Set ($name) - Unknown argument $cmd or wrong parameter(s), choose one of $list";

}

sub DBPlan_Attr(@) {
   my ($cmd,$name,$attrName,$attrVal) = @_;
   my $hash = $defs{$name};

   # $cmd can be "del" or "set"
   # $name is device name
   # attrName and attrVal are Attribute name and value

   if ($cmd eq "set") {
     if ($attrName eq "dbplan-travel-date") {
       if (!($attrVal =~ m/(0[1-9]|1[0-9]|2[0-9]|3[01]).(0[1-9]|1[012]).\d\d/s ) ) {
          Log3 $name, 4, "DBPlan_Attr ($name) - $attrVal is a wrong date";
          return ("DBPlan_Attr: $attrVal is a wrong date. Format is dd.mm.yy");
       }

     } elsif ($attrName eq "dbplan-travel-time") {
       if (!($attrVal =~ m/(?:0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]/s)) {
          Log3 $name, 4, "DBPlan_Attr ($name) - $attrVal is a wrong time";
          return ("DBPlan_Attr: $attrVal is a wrong time. Format is hh:mm");
       }
     }

   }
	
   if ($attrName eq "dbplan-disable") {
      if($cmd eq "set") {
         if($attrVal eq "0") {
            RemoveInternalTimer($hash);
            InternalTimer(gettimeofday()+2, "DBPlan_Get_DB_Info", $hash, 0); # if ($hash->{DevState} eq "disabled");
            $hash->{DevState}='initialized';
            #$hash->{state}='initialized';
            readingsSingleUpdate($hash, "state", "initialized", 1);
            Log3 $name, 4, "DBPlan_Attr ($name) - interval timer enabled with interval $hash->{Interval} (sec)";
         } else {
            $hash->{DevState} = 'disabled';
            #$hash->{state} = 'disabled';
            readingsSingleUpdate($hash, "state", "disabled", 1);
            RemoveInternalTimer($hash);    
            Log3 $name, 4, "DBPlan_Attr ($name) - interval timer disabled";
         }
         $attr{$name}{$attrName} = $attrVal;   

      } elsif ($cmd eq "del") {
         RemoveInternalTimer($hash);
         InternalTimer(gettimeofday()+2, "DBPlan_Get_DB_Info", $hash, 0) if ($hash->{DevState} eq "disabled");
         $hash->{DevState}='initialized';
         #$hash->{state}='initialized';
         readingsSingleUpdate($hash, "state", "initialized", 1);
         Log3 $name, 4, "DBPlan_Attr ($name) - interval timer enabled with interval $hash->{Interval} (sec)";
      }

   } elsif ($attrName eq "dbplan_plan_url") {
      if($cmd eq "set") {
        $hash->{PLAN_URL} = $attrVal;
        $attr{$name}{$attrName} = $attrVal;   
      } elsif ($cmd eq "del") {
        $hash->{PLAN_URL} = 'http://reiseauskunft.bahn.de/bin/query.exe/dox?S=departure&Z=destination&start=1&rt=1';
      }
      Log3 $name, 4, "DBPlan_Attr ($name) - url set to " . $hash->{PLAN_URL};

   } elsif ($attrName eq "dbplan_table_url") {
      if($cmd eq "set") {
        $hash->{TABLE_URL} = $attrVal;
        $attr{$name}{$attrName} = $attrVal;   
      } elsif ($cmd eq "del") {
        $hash->{TABLE_URL} = 'http://reiseauskunft.bahn.de/bin/bhftafel.exe/dox?&rt=1&input=station';
      }
      Log3 $name, 4, "DBPlan_Attr ($name) - url set to " . $hash->{TABLE_URL};

   } elsif ($attrName eq "dbplan_station") {
      if($cmd eq "set") {
        $hash->{helper}{STATION} = $attrVal;
        $attr{$name}{$attrName} = $attrVal;

        if(!defined($hash->{helper}{DESTINATION}) && ($hash->{BASE_TYPE} eq "plan")) {
          $hash->{DevState} = 'defined';
          #$hash->{state} = 'defined';
          readingsSingleUpdate($hash, "state", "defined", 1);
        } else {
          $hash->{DevState} = 'initialized';
          #$hash->{state} = 'initialized';
          readingsSingleUpdate($hash, "state", "initialized", 1);
        }
        Log3 $name, 3, "DBPlan_Attr ($name) - station set to " . $hash->{helper}{STATION};

      } elsif($cmd eq "del") {
        delete($hash->{helper}{STATION}) if(defined($hash->{helper}{STATION}));
        $hash->{DevState} = 'defined';
        #$hash->{state} = 'defined';
        readingsSingleUpdate($hash, "state", "defined", 1);
        Log3 $name, 3, "DBPlan_Attr ($name) - deleted $attrName : $attrVal";
      }

   } elsif ($attrName eq "dbplan_destination") {
      if($cmd eq "set") {
        $hash->{helper}{DESTINATION} = $attrVal;
        $attr{$name}{$attrName} = $attrVal;

        unless(defined($hash->{helper}{STATION})) {
          $hash->{DevState} = 'defined';
          #$hash->{state} = 'defined';
          readingsSingleUpdate($hash, "state", "defined", 1);
        } else {
          $hash->{DevState} = 'initialized';
          #$hash->{state} = 'initialized';
          readingsSingleUpdate($hash, "state", "initialized", 1);
        }
        Log3 $name, 3, "DBPlan_Attr ($name) - destination set to " . $hash->{helper}{DESTINATION};

      } elsif ($cmd eq "del") {
        if(($hash->{BASE_TYPE} eq "table") && defined($hash->{helper}{STATION})) {
          $hash->{DevState} = 'initialized';
          #$hash->{state} = 'initialized';
          readingsSingleUpdate($hash, "state", "initialized", 1);
        } else {
          $hash->{DevState} = 'defined';
          #$hash->{state} = 'defined';
          readingsSingleUpdate($hash, "state", "defined", 1);
        }
        delete($hash->{helper}{DESTINATION}) if(defined($hash->{helper}{DESTINATION}));
        Log3 $name, 3, "DBPlan_Attr ($name) - deleted $attrName : $attrVal";
      }

   } elsif ($attrName eq "dbplan-station-file") {
      if($cmd eq "set") {
        return DBPlan_loadStationFile($hash, $attrVal);

      } elsif ($cmd eq "del") {
        delete($hash->{helper}{STATION_NAMES}) if(defined($hash->{helper}{STATION_NAMES}));
        Log3 $name, 3, "DBPlan_Attr ($name) - deleted $attrName : $attrVal";
      }

   } elsif ($attrName eq "dbplan-base-type") {
      if($cmd eq "set") {
        $hash->{BASE_TYPE} = $attrVal;
        $attr{$name}{$attrName} = $attrVal;
        RemoveInternalTimer($hash);
        InternalTimer(gettimeofday()+2, "DBPlan_Get_DB_Info", $hash, 0);
        $hash->{DevState}='initialized';
        #$hash->{state}='initialized';
        readingsSingleUpdate($hash, "state", "initialized", 1);

      } elsif ($cmd eq "del") {
        $hash->{BASE_TYPE} = 'plan';
      }

      my $ret;
      $ret = fhem("deletereading $name table.*", 1);
      $ret = fhem("deletereading $name plan.*", 1);
      $ret = fhem("deletereading $name travel.*", 1);
      Log3 $name, 4, "DBPlan_Attr ($name) - base type set to " . $hash->{BASE_TYPE};

   } else {
      if($cmd eq "set") {
          $attr{$name}{$attrName} = $attrVal;   
          Log3 $name, 4, "DBPlan_Attr ($name) - set $attrName : $attrVal";
      } elsif ($cmd eq "del") {
          Log3 $name, 4, "DBPlan_Attr ($name) - deleted $attrName : $attrVal";
      }
   }

   return undef;
}

#####################################
# generating bit pattern for DB products
#
# Bit Nummer Produktklasse
#         0  ICE-ZÃƒÂ¼ge
#         1  Intercity- und EurocityzÃƒÂ¼ge
#         2  Interregio- und SchnellzÃƒÂ¼ge
#         3  Nahverkehr, sonstige ZÃƒÂ¼ge
#         4  S-Bahnen
#         5  Busse
#         6  Schiffe
#         7  U-Bahnen
#         8  StraÃƒÅ¸enbahnen
#         9  Anruf Sammeltaxi
#
sub DBPlan_products($)
{
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my @prod_list = split("(,|\\|)", AttrVal($name, "dbplan_journey_prod", "none"));

    my $products = 0;

    return $products if((grep { /^(Alle)$/ } @prod_list));

    $products += 1 if((grep { /^(ICE-Zuege)$/ } @prod_list));
    $products += 2 if((grep { /^(Intercity-Eurocityzuege)$/ } @prod_list));
    $products += 4 if((grep { /^(Interregio-Schnellzuege)$/ } @prod_list));
    $products += 8 if((grep { /^(Nahverkehr)$/ } @prod_list));
    $products += 16 if((grep { /^(S-Bahnen)$/ } @prod_list));
    $products += 32 if((grep { /^(Busse)$/ } @prod_list));
    $products += 64 if((grep { /^(Schiffe)$/ } @prod_list));
    $products += 128 if((grep { /^(U-Bahnen)$/ } @prod_list));
    $products += 256 if((grep { /^(Strassenbahnen)$/ } @prod_list));
    $products += 512 if((grep { /^(Anruf-Sammeltaxi)$/ } @prod_list));

    return $products;
}

#####################################
# generating bit pattern DB options
sub DBPlan_options($)
{
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my @opt_list = split("(,|\\|)", AttrVal($name, "dbplan_journey_opt", "none"));

    my $options = 0;

    $options += 1 if((grep { /^(Direktverbindung)$/ } @opt_list));
    $options += 2 if((grep { /^(Direktverbindung+Schlafwagen)$/ } @opt_list));
    $options += 4 if((grep { /^(Direktverbindung+Liegewagen)$/ } @opt_list));
    $options += 8 if((grep { /^(Fahrradmitnahme)$/ } @opt_list));

    return $options;
}

#####################################
# generating url with defined options
sub DBPlan_make_url($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $plan_url = "";
    my $oTmp;

    my @prod_list = split("(,|\\|)", AttrVal($name, "dbplan_journey_prod", "none"));
    my @opt_list = split("(,|\\|)", AttrVal($name, "dbplan_journey_opt", "none"));

    my $products = DBPlan_products($hash);
    my $options = DBPlan_options($hash);
	
    my $station = $hash->{helper}{STATION};
    $station =~ s/ /+/g;

    if($hash->{BASE_TYPE} eq "plan") {
      $plan_url = $hash->{PLAN_URL};
      $plan_url =~ s/departure/$station/;

      $oTmp = $hash->{helper}{DESTINATION};
      $oTmp =~ s/ /+/g;
      $plan_url =~ s/destination/$oTmp/;

      $oTmp = AttrVal($name, "dbplan_via_1", "");
      $plan_url .= '&V1='.$oTmp if($oTmp ne "");

      $oTmp = AttrVal($name, "dbplan_via_2", "");
      $plan_url .= '&V2='.$oTmp if($oTmp ne "");

      $oTmp = AttrVal($name, "dbplan_tariff_class", "");
      $plan_url .= '&tariffClass='.$oTmp if($oTmp ne "");

    } else {
      $plan_url = $hash->{TABLE_URL};
      $plan_url =~ s/station/$station/;

      $oTmp = AttrVal($name, "dbplan_reg_train", "");
      $oTmp =~ s/ /+/g;
      $plan_url .= '&REQTrain_name=' . $oTmp;

      $oTmp = AttrVal($name, "dbplan_delayed_Journey", "off");
      $oTmp .= '&delayedJourney=' . $oTmp if($oTmp ne "off");

      $oTmp = AttrVal($name, "dbplan_max_Journeys", "off");
      $plan_url .= '&maxJourneys=' . $oTmp;

      $plan_url .= '&boardType=' . substr(AttrVal($name, "dbplan_board_type", "depart"),0,3);

    }

    $plan_url .= '&journeyProducts='.$products if($products > 0);
    $plan_url .= '&journeyOptions='.$options if($options > 0);

    my $travel_date = AttrVal($name, "dbplan_travel-date", "");
    my $travel_time = AttrVal($name, "dbplan_travel_time", "");
    my $time_sel = AttrVal($name, "dbplan_time_selection", "depart");

    $plan_url .= '&date='.$travel_date if($travel_date ne "");

    if($travel_time ne "") {
      $plan_url .= '&time='.$travel_time;
    } elsif ( $hash->{Time_Offset} > 0 ) {
      $plan_url .= '&time='.strftime( "%H:%M", localtime(time+60*$hash->{Time_Offset}));
    }

    if($travel_date ne "" || $travel_time ne "") {
      $plan_url .= '&timesel='.$time_sel if($hash->{BASE_TYPE} eq "plan");
    }

    $oTmp = AttrVal($name, "dbplan_addon_options", "");
    $plan_url .= $oTmp if($oTmp ne "");

    $plan_url .= '&'; # see parameter description

    if (exists($hash->{helper}{plain})) {
       $plan_url =~ s/dox/dl/g;
    }

    Log3 $name, 4, "DBPlan ($name) - DB timetable: calling url: $plan_url";


    return ($plan_url);

}

#####################################
# Getting the DB main stationtable
sub DBPlan_Get_DB_Plain_Text($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $param;
    $param->{url}        = DBPlan_make_url($hash);
    $param->{noshutdown} = AttrVal($name, "dbplan-remote-noshutdown", 1);
    $param->{timeout}    = AttrVal($name, "dbplan-remote-timeout", 5);
    $param->{loglevel}   = AttrVal($name, "dbplan-remote-loglevel", 4);
                     
    Log3 $name, 4, "DBPlan ($name) - Get_DB_Plain_Textget: DB plain text info";             
    
    my ($err, $data) = HttpUtils_BlockingGet($param);
    
    Log3 $name, 5, "DBPlan ($name) - Get_DB_Plain_Text: received http response code ".$param->{code} if(exists($param->{code}));
    
    if ($err ne "") 
    {
        Log3 $name, 3, "DBPlan ($name) - Get_DB_Plain_Text: got error while requesting DB info: $err";
        return "got error while requesting DB info: $err";
    }

    if($data eq "" and exists($param->{code}))
    {
        Log3 $name, 3, "DBPlan ($name) - Get_DB_Plain_Text: received http code ".$param->{code}." without any data after requesting DB plain text";
        return  "received no data after requesting DB plain text";
    }

    my $pattern = '\<PRE\>(.*?)\<\/PRE\>';

    Log3 $name, 5, "DBPlan ($name) - $data";

    Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Stationtable for plain text: finished";

    if ($data =~ m/$pattern/is) {
      return $1;
    } else {
      return ( "no information found" );
    }

    return ($data);

}

#####################################
# Getting the DB main stationtable
sub DBPlan_Get_DB_Info($)
{
    my ($hash) = @_;
    my $name = $hash->{NAME};
	
    if($hash->{DevState} eq 'active' || $hash->{DevState} eq 'initialized'  || $hash->{DevState} eq 'defined') {
       my $nt = gettimeofday()+$hash->{Interval};
       $hash->{TRIGGERTIME} = $nt;
       $hash->{TRIGGERTIME_FMT} = FmtDateTime($nt);
       RemoveInternalTimer($hash);

       InternalTimer($nt, "DBPlan_Get_DB_Info", $hash, 1) if (int($hash->{Interval}) > 0);

       Log3 $name, 5, "DBPlan ($name) - DBPlan_Get_DB_Info: restartet InternalTimer with $hash->{Interval}";
    }

    unless(defined($hash->{helper}{STATION}))
    {
        Log3 $name, 3, "DBPlan ($name) - DBPlan_Get_DB_Info: no valid station defined";
        return;
    }

    if($hash->{BASE_TYPE} eq "plan") {
      unless(defined($hash->{helper}{DESTINATION}))
      {
        Log3 $name, 3, "DBPlan ($name) - Get_DB_Info: no valid destination defined";
        return; 
      }
      $hash->{callback}   = \&DBPlan_Parse_Timetable;
    } else {
      $hash->{callback}   = \&DBPlan_Parse_Stationtable;
    }

    $hash->{url}        = DBPlan_make_url($hash);   #$plan_url;
    $hash->{noshutdown} = AttrVal($name, "dbplan-remote-noshutdown", 1);
    $hash->{timeout}    = AttrVal($name, "dbplan-remote-timeout", 5);
    $hash->{loglevel}   = AttrVal($name, "dbplan-remote-loglevel", 4);

    Log3 $name, 4, "DBPlan ($name) - DBPlan_Get_DB_Info: next getting $hash->{url}";

    HttpUtils_NonblockingGet($hash);

    return undef;

}

#####################################
# Parsing the DB main station table
#
sub DBPlan_Parse_Stationtable($)
{
    my ($hash, $err, $data) = @_;
    my $name = $hash->{NAME};

    delete($hash->{error}) if(exists($hash->{error}));
    my $ret = fhem("deletereading $name table_.*", 1);

    
    if ($err) {
       Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Stationtable: got error in callback: $err";
       return undef;
    }

    if($data eq "")
    {
       Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Stationtable: received http without any data after requesting DB stationtable";
       return undef;
    }

    Log3 $name, 5, "DBPlan ($name) - DBPlan_Parse_Stationtable: Callback called with Hash: $hash, data: $data\r\n";

    if(AttrVal($name, "verbose", 3) >= 5) {
       $hash->{Stationtable} = $data;
    }

    ##################################################################################
    # only for debugging
    if(AttrVal($name, "verbose", 3) >= 5) {
       readingsBeginUpdate($hash);
       readingsBulkUpdate( $hash, "dbg_db_plan", $data );
       readingsEndUpdate( $hash, 1 );
    }

    my $i;
    my $ret;
    my $defChar = AttrVal($name, "dbplan-default-char", "delete");

    my $pattern = '';

    if ($data =~ m/\<div.class="haupt errormsg"\>(.*?)\<\/div\>/s) {
        Log3 $name, 3, "DBPlan ($name) - error in DB request. Bitte Log prÃƒÂ¼fen.";
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "table_error", "error in DB request: " . DBPlan_decode(DBPlan_html2uml($1)) );
        readingsEndUpdate( $hash, 1 );
        $pattern = '\<title\>Deutsche Bahn - Abfahrt\<\/title\>(.*?)\<p class="webtrack"\>';
#        if ($data =~ m/$pattern/s) {
#           my $error_text = DBPlan_html2txt($1);
#           Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Stationtable: error description of DB stationtable request: $error_text";
#        }
        return undef;
    }

    Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Stationtable: successfully identified";

    ##################################################################################
    # Parsing connection table.
    $pattern = '\<div.class="sqdetails.*?trow"\>.*?\<\/div\>';

    my $count = 0;
    my $index = "";
    my $btype = AttrVal($name, "dbplan_board_type", "depart") . "_";

    foreach my $line ($data =~ m/$pattern/gs) {
      $count ++;
      $index = $btype . sprintf("%02d", $count);

      ##################################################################################
      # only for debugging
      if(AttrVal($name, "verbose", 3) >= 5) {
         readingsBeginUpdate($hash);
         readingsBulkUpdate( $hash, "dbg_connect_table_$index", $line ) if(defined($line));
         readingsEndUpdate( $hash, 1 );
      }

      $line =~ s/\x0a//g;

      Log3 $name, 5, "$line";

      # $pattern = '<span class="bold">S     13</span></a>&gt;&gt;Sindorf<br /><span class="bold">15:34</span>&nbsp;<span class="okmsg">+2</span></span>,&nbsp;&nbsp;Gl. 2</div>';

      my $table_row = "";

      # Zug
      $pattern = '\<span.class="bold"\>(.*?)\<\/span\>';
      if ($line =~ m/$pattern/s) {
        $table_row .= $1;
      }

      # nächster Bahnhof
      $pattern = '\<\/span\>\<\/a\>&gt;&gt;(.*?)\<br.\/\>\<span.class';
      if ($line =~ m/$pattern/s) {
        $table_row .= "|" . $1;
      }

      # Uhrzeit ohne Versp�tung
      $pattern = '\<br.\/\>\<span.class="bold"\>(.*?)\<\/span\>\<\/div\>';
      if ($line =~ m/$pattern/s) {
        $table_row .= "|" . $1;
      }

      # Uhrzeit mit Versp�tung
      $pattern = '\<br.\/\>\<span.class="bold"\>(.*?)\<\/span\>&nbsp;';
      if ($line =~ m/$pattern/s) {
        $table_row .= "|" . $1;
      }

      # Verspätung
      $pattern = '\<span.class="okmsg"\>(.*?)\<\/span\>';
      if ($line =~ m/$pattern/s) {
        $table_row .= "|" . $1;
      } else {
        $table_row .= "|-";
      }

      # Verspätung rot
      $pattern = '\<span.class="red"\>(.*?)\<\/span\>,&nbsp;&nbsp;';
      if ($line =~ m/$pattern/s) {
        $table_row .= "|" . $1;
      } else {
        $table_row .= "|-";
      }

      # Gleis
      $pattern = '&nbsp;&nbsp;(.*?)\<\/div\>';
      my $pattern1 = '&nbsp;&nbsp;(.*?),\<br\/\>\<a.class="red.underline"';
      my $pattern2 = '&nbsp;&nbsp;(.*?)\<br.\/\>\<span.class="red"\>.*?\<\/span\>\<br.\/\>';
      if ($line =~ m/$pattern1/s) {
        $table_row .= "|" . $1;
      } elsif ($line =~ m/$pattern2/s) {
        $table_row .= "|" . $1;
      } else {
        if ($line =~ m/$pattern/s) {
          $table_row .= "|" . $1;
        } else {
          $table_row .= "|-";
        }
      }

      # Hinweise
      $pattern1 = '\<br\/\>\<a.class="red.underline".*?\<span.class="red"\>(.*?)\<\/span\>\<\/a\>\<\/span\>';
      $pattern2 = '\<br.\/\>\<span.class="red.*?">(.*?)\<\/span>\<br.\/\>\<span.class="red.*?"\>(.*?)\<\/span\>\<\/div\>';
      if ($line =~ m/$pattern1/s) {
        # Ersatzfahrt&nbsp;ICE 2555
        $table_row .= "|" . $1;
      } elsif ($line =~ m/$pattern2/s) {
        $table_row .= "|" . $1 . " " . $2;
      } else {
        $table_row .= "|-";
      }

      my $convChar = AttrVal($name, "dbplan-special-char-decode", "latin1(default)");
      if($convChar eq "latin1(default)"){
        $table_row = DBPlan_html2uml($table_row);
      }
      if($convChar eq "utf8"){
        $table_row = DBPlan_decode(DBPlan_html2uml($table_row));
      }

      readingsBeginUpdate($hash);
      readingsBulkUpdate( $hash, "table_$index", $table_row );
      readingsEndUpdate( $hash, 1 );
    
    }

    unless($count) {
      Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Stationtable: no station table found";
      readingsBeginUpdate($hash);
      readingsBulkUpdate( $hash, "table_row_cnt", "0" );
      readingsEndUpdate( $hash, 1 );

    } else {
      Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Stationtable: table plans read successfully";

      if($hash->{DevState} eq 'initialized' || $hash->{DevState} eq 'inactiv') {
        $hash->{DevState}='active' ;
        #$hash->{state}='active';
        readingsSingleUpdate($hash, "state", "activ", 1);
      }

      readingsBeginUpdate($hash);
      readingsBulkUpdate( $hash, "table_row_cnt", sprintf("%02d", $count));
      readingsEndUpdate( $hash, 1 );
    }

    return undef;

}

#####################################
# Parsing the DB travel notes
sub DBPlan_Parse_Travel_Notes($)
{
    my ($hash, $err, $data) = @_;
    my $name = $hash->{NAME};
    my $index = $hash->{note_index};
	
    if ($err) {
        Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: got error in callback: $err";
        return;
    }

    if($data eq "")
    {
        Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: received http without any data after requesting DB travel notes";
        return;
    }

    # $data = `cat /opt/fhem/FHEM/test.html`;    # note backticks, qw"cat ..." also works
    #use HTML::Tree;
    #my $tree = HTML::Tree->new();

    #$tree->parse($data);
    #my @inhalt = $tree->look_down('class', qr/rline.*/);

    #Log3 $name, 3, "DBPlan ($name) - DBPlan_Tree: vorher";

    #foreach my $thumb (@inhalt) {
    #  my $ausgabe = $thumb->as_text;
    #  Log3 $name, 3, "DBPlan ($name) - DBPlan_Tree: $ausgabe\r\n";
    #}

    #Log3 $name, 3, "DBPlan ($name) - DBPlan_Tree: nach";

    # my $ausgabe = $tree->as_text;
    # Log3 $name, 3, "DBPlan ($name) - DBPlan_Tree: $ausgabe\r\n";

    my $pattern;
    # "dbplan-special-char-decode:none,utf8,latin1(default) "
    my $convChar = AttrVal($name, "dbplan-special-char-decode", "latin1(default)");

    readingsBeginUpdate($hash);

    Log3 $name, 5, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: Callback called: Hash: $hash, data: $data\r\n";

    ##################################################################################
    # only for debugging
    if(AttrVal($name, "verbose", 3) >= 5) {
       readingsBulkUpdate( $hash, "dbg_travel_notes_HTML_1", $data );
    }

    ##################################################################################
    # Parsing error information
    $pattern = '\<div.class="errormsg"\>..(.*?)\<\/div\>';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Error: travel error information for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_note_error_$index", "Fahrt faellt aus");
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Error: no error information for plan $index found";
    }

    ##################################################################################
    # Parsing notification
    $pattern = '\<\/script\>.\<div.class="red.bold.haupt".\>(.*?)\<br.\/\>.\<\/div\>';

    if ($data =~ m/$pattern/s) {
       my $notification = $1;
       if($convChar eq "latin1(default)"){
         $notification = DBPlan_html2uml($notification);
       }
       if($convChar eq "utf8"){
         $notification = DBPlan_decode(DBPlan_html2uml($notification));
       }
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel notification for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_note_text_$index", $notification)
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no canceling for plan $index found";
    }

    ##################################################################################
    # Parsing notification
    $pattern = '(Fahrt f&#228;llt aus)';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel notification for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_note_text_$index", "Fahrt faellt aus");
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no canceling for plan $index found";
    }

    ##################################################################################
    # Parsing notification
    $pattern = '(Aktuelle Informationen zu der Verbindung)';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel notification for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_note_text_$index", "Aktuelle Informationen liegen vor");
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no actual informations for plan $index found";
    }

    ##################################################################################
    # Parsing notification
    #$pattern = 'alt="".\/\>Angebot.w\&\#228\;hlen.*?\>(.*?)\<\/div\>.\<div.class="querysummary1.clickarea"';

    #if ($data =~ m/$pattern/s) {
    #   Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel notification for plan $index read successfully";
    #   readingsBulkUpdate( $hash, "travel_note_text_$index", DBPlan_html2txt($1));
    #} else {
    #   Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel notes for plan $index found";
    #}

    ##################################################################################
    # Parsing notification
    #$pattern = 'alt="".\/\>Angebot.w\&\#228\;hlen(.*?)\<\/div\>.\<div class="clickarea';

    #if ($data =~ m/$pattern/s) {
    #   Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel notification for plan $index read successfully";
    #   readingsBulkUpdate( $hash, "travel_note_text_$index", DBPlan_html2txt($1));
    #} else {
    #   Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel notes for plan $index found";
    #}

    my $plattform = "";

    ##################################################################################
    # Parsing deaparture plattform
    $pattern = '\<\/span\>.(Gl.*?).\<br.\/\>.\<\/div\>.\<div.class="rline.haupt.mot"\>';

    $plattform = 'none';
    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel departure plattform for plan $index read successfully";
       $plattform = $1;
       if($convChar eq "latin1(default)"){
         $plattform = DBPlan_html2uml($plattform);
       }
       if($convChar eq "utf8"){
         $plattform = DBPlan_decode(DBPlan_html2uml($plattform));
       }
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel departure plattform for plan $index found";
       readingsBulkUpdate( $hash, "travel_departure_$index", $plattform);
    }

    # and then parsing departure place
    $pattern = '"rline.haupt.routeStart".style="."\>.\<span.class="bold"\>(.*?)\<\/span\>';

    if ($data =~ m/$pattern/s) {
       $plattform = $1.' - '.$plattform;
       if($convChar eq "latin1(default)"){
         $plattform = DBPlan_html2uml($plattform);
       }
       if($convChar eq "utf8"){
         $plattform = DBPlan_decode(DBPlan_html2uml($plattform));
       }
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel departure for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_departure_$index", $plattform);
    }

    if( $plattform eq "none") {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel departure for plan $index found";
    }

    ##################################################################################
    # vehicle number(s)
    $pattern = '\<div.class="rline.haupt.mot"\>.\<div.class="motSection"\>.*?\<span.class="bold"\>.(.*?).\<\/span\>.\<\/a\>.\<\/div\>.\<\/div\>.\<div.class="rline.haupt.route.*?"\>';

    $plattform = 'none';
    if ($data =~ m/$pattern/s) {
       $plattform = '';
       foreach my $vehicle ($data =~ m/$pattern/gs) {
          $vehicle =~ s/\r|\n//g;
          $vehicle =~ s/&nbsp.*//gs;
          $vehicle =~ s/\<span.class="red.*//gs;
          $vehicle =~ s/\s+/ /g;
          $plattform .= $vehicle . " | ";
       }
       $plattform = substr($plattform, 0, -3);
       readingsBulkUpdate( $hash, "travel_vehicle_nr_$index", $plattform);
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Vehicle_Nr: vehicle numbers for plan $index read successfully";
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Vehicle_Nr: no vehicle numbers for plan $index found";
    }

    ##################################################################################
    # Parsing destination plattform
    $pattern = '\<div.class="rline.haupt.routeEnd.routeEnd__IV"\>.*?(Gl.*?).\<br.\/\>.\<span.class="bold"\>.*?\<\/span\>';

    $plattform = 'none';
    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel destination plattform for plan $index read successfully";
       $plattform = $1;
       if($convChar eq "latin1(default)"){
         $plattform = DBPlan_html2uml($plattform);
       }
       if($convChar eq "utf8"){
         $plattform = DBPlan_decode(DBPlan_html2uml($plattform));
       }
       readingsBulkUpdate( $hash, "travel_destination_$index", $plattform);
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel destination plattform for plan $index found";
    }

    # and then parsing destination place
    $pattern = '\<div.class="rline.haupt.routeEnd.routeEnd__IV"\>.*?\<br.\/\>.\<span.class="bold"\>(.*?)\<\/span\>';

    if ($data =~ m/$pattern/s) {
       $plattform = $1.' - '.$plattform;
       if($convChar eq "latin1(default)"){
         $plattform = DBPlan_html2uml($plattform);
       }
       if($convChar eq "utf8"){
         $plattform = DBPlan_decode(DBPlan_html2uml($plattform));
       }
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: travel destination for plan $index read successfully";
       readingsBulkUpdate( $hash, "travel_destination_$index", $plattform);
    } 

    if ($plattform eq 'none') {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Travel_Notes: no travel destination for plan $index found";
    }

    ##################################################################################
    # delays
    $pattern = '\<\/span\>.\<span.class="querysummary2".id="dtlOpen_2"\>.*?.\<span.class=".*?"\>(.*?)\<\/span\>.*?\<\/div\>.\<div.class="rline.haupt.routeStart".style="."\>';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Delays: delays for plan $index read successfully";
       readingsBulkUpdate( $hash, "plan_departure_delay_$index", $1);
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Delays: no delays for plan $index found";
    }

    $pattern = '\<\/span\>.\<span.class="querysummary2".id="dtlOpen_2"\>.*?.\<span.class=".*?"\>(.*?)\<\/span\>.*?\<span.class=".*?"\>(.*?)\<\/span\>.\<\/span\>.\<\/a\>.\<\/div\>.\<div.class="rline.haupt.routeStart".style="."\>';

    if ($data =~ m/$pattern/s) {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Delays: delays for plan $index read successfully";
       readingsBulkUpdate( $hash, "plan_departure_delay_$index", $1);
       readingsBulkUpdate( $hash, "plan_arrival_delay_$index", $1);
    } else {
       Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Delays: no delays for plan $index found";
    }

    readingsEndUpdate($hash, 1);

    ##################################################################################
    # Recursiv call until index = 0
    $index -= 1;
	
    if($index <= 0) {
       Log3 $name, 4, "DBPlan ($name) - DB notes: parsed all notes";
       return;
    }

    $hash->{note_index} = $index;
    $hash->{url}        = ReadingsVal($name, "travel_note_link_$index", "");
    $hash->{callback}   = \&DBPlan_Parse_Travel_Notes;
    $hash->{noshutdown} = AttrVal($name, "dbplan-remote-noshutdown", 1);
    $hash->{timeout}    = AttrVal($name, "dbplan-remote-timeout", 5);
    $hash->{loglevel}   = AttrVal($name, "dbplan-remote-loglevel", 4);

    Log3 $name, 4, "DBPlan ($name) - DB notes ($index): next getting $hash->{url}";

    HttpUtils_NonblockingGet($hash);

    return;
}

#####################################
# Parsing the DB main timetable
#
sub DBPlan_Parse_Timetable($)
{
    my ($hash, $err, $data) = @_;
    my $name = $hash->{NAME};

    delete($hash->{error}) if(exists($hash->{error}));
    
    if ($err) {
       Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: got error in callback: $err";
       return undef;
    }

    if($data eq "")
    {
       Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: received http without any data after requesting DB timetable";
       return undef;
    }

    Log3 $name, 5, "DBPlan ($name) - DBPlan_Parse_Timetable: Callback called with Hash: $hash, data: $data\r\n";

    if(AttrVal($name, "verbose", 3) >= 5) {
       $hash->{Timetable} = $data;
    }

    ##################################################################################
    # only for debugging
    if(AttrVal($name, "verbose", 3) >= 5) {
       readingsBeginUpdate($hash);
       readingsBulkUpdate( $hash, "dbg_db_plan", $data );
       readingsEndUpdate( $hash, 1 );
    }

    my $i;
    my $ret;
    my $defChar = AttrVal($name, "dbplan-default-char", "none");

    $ret = fhem("deletereading $name dbg.*", 1);

    if($defChar eq "delete") {

      $ret = fhem("deletereading $name plan.*", 1);
      $ret = fhem("deletereading $name travel.*", 1);
      Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: readings deleted";

    } else {

      $defChar =" " if($defChar eq "nochar");
	
      readingsBeginUpdate($hash);

      for($i=1; $i<=3; $i++) {

         readingsBulkUpdate( $hash, "plan_error", $defChar);
         readingsBulkUpdate( $hash, "plan_departure_$i", $defChar);
         readingsBulkUpdate( $hash, "plan_arrival_$i", $defChar);
         readingsBulkUpdate( $hash, "plan_connection_$i", $defChar);
         readingsBulkUpdate( $hash, "plan_departure_delay_$i", $defChar );
         readingsBulkUpdate( $hash, "plan_arrival_delay_$i", $defChar );
         readingsBulkUpdate( $hash, "travel_duration_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_change_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_price_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_note_link_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_note_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_note_text_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_note_error_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_departure_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_destination_$i", $defChar);
         readingsBulkUpdate( $hash, "travel_vehicle_nr_$i", $defChar);

      }

      readingsEndUpdate( $hash, 1 );

      Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: readings filled with: $defChar";
    }

    my $pattern = '\<div class="haupt bline leftnarrow"\>(.*?)\<div class="bline bggrey stdpadding"\>';

    if ($data =~ m/MOBI_ASK_DEU_de_error/s) {
        Log3 $name, 3, "DBPlan ($name) - error in DB request. Bitte Log prÃƒÂ¼fen.";
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "plan_error", "error in DB request" );
        readingsEndUpdate( $hash, 1 );
        if ($data =~ m/$pattern/s) {
           my $error_text = DBPlan_html2txt($1);
           Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: error description of DB timetable request: $error_text";
        }
        return undef;
    }


    Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: successfully identified";

    ##################################################################################
    # Testing correct answer. DB timetable will show three connection plans
    $pattern = 'verbindung.start.=.new.Object\(\);(.*?)digitalData.verbindung.push\(verbindung\)'
              .'.*?'
              .'verbindung.start.=.new.Object\(\);(.*?)digitalData.verbindung.push\(verbindung\)'
              .'.*?'
              .'verbindung.start.=.new.Object\(\);(.*?)digitalData.verbindung.push\(verbindung\)';

    if ($data =~ m/$pattern/s) {
      ##################################################################################
      # only for debugging
      if(AttrVal($name, "verbose", 3) >= 5) {
         readingsBeginUpdate($hash);
         readingsBulkUpdate( $hash, "dbg_connect_plan_1", $1 ) if(defined($1));
         readingsBulkUpdate( $hash, "dbg_connect_plan_2", $2 ) if(defined($2));
         readingsBulkUpdate( $hash, "dbg_connect_plan_3", $3 ) if(defined($3));
         readingsEndUpdate( $hash, 1 );
      }
      Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: connection plans read successfully";

      if($hash->{DevState} eq 'initialized' || $hash->{DevState} eq 'inactiv') {
        $hash->{DevState}='active';
        #$hash->{state}='active';
        readingsSingleUpdate($hash, "state", "active", 1);
      }

    } else {
      Log3 $name, 3, "DBPlan ($name) - DBPlan_Parse_Timetable: no connection plans found";
      return undef;
    }

    ##################################################################################
    # Extracting connection plan with TableExtract (Three is default)

    my @plan;
    my @planrow;

    my $notelink = '';

    $plan[1] = $1;
    $plan[2] = $2;
    $plan[3] = $3;

    my $rc = eval {
        require HTML::TableExtract;
        HTML::TableExtract->import();
        1;
    };

    unless($rc)
    {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "plan_error", "Error loading HTML::TableExtract" );
        readingsEndUpdate( $hash, 1 );
        Log3 $name, 2, "DBPlan ($name) - Timetable: Error loading HTML::TableExtract. May be this module is not installed.";
        return;
    }

    $data =~ s/\<td.class="ovHeadNoPad"\>&nbsp;\<\/td\>/\<td class="ovHead"\>\nLeer\<br \/\>\nLeer\n\<\/td\>/g;
    $data =~ s/&nbsp;/ /g;

    # Log3 $name, 2, $data;
    
    my @headers = split(/ /, AttrVal($name, "dbplan-table-headers", "An Leer Dauer Preis"));
    Log3 $name, 4, "DBPlan ($name) - Timetable-Headers: @headers";
    my $timetable = HTML::TableExtract->new( headers => \@headers );
    my $retRow = "";

    Log3 $name, 4, "DBPlan ($name) - Timetable: data for HTML::TableExtract: \n $data";

    $ret = $timetable->parse($data);

    $i = 0;
    my $filler = "";

    foreach my $ts ($timetable->tables) {
      Log3 $name, 5, "DBPlan ($name) - Timetable: Erste Schleife";

      foreach my $row ($timetable->rows) {
        Log3 $name, 5, "DBPlan ($name) - Timetable: Zweite Schleife";

        Log3 $name, 4, "DBPlan ($name) - Timetable-Org1: $retRow";

        if(@$row) {
          my @myValues = map defined($_) ? $_ : '', @$row;
          $retRow = join(';', @myValues);
          $retRow =~ s/\n|\r/;/g; #s,[\r\n]*,,g;
          if($defChar ne "delete") {
            $retRow =~ s/Ã‚Â /$defChar/g;
          } else {
            $retRow =~ s/Ã‚Â /$filler/g;
          }
        }

        Log3 $name, 4, "DBPlan ($name) - Timetable-Org2: $retRow";

        $planrow[$i++] = $retRow;
      }
    }

    unless(@planrow) {
      Log3 $name, 2, "DBPlan ($name) - Timetable: HTML::TableExtract failed.";
      readingsBeginUpdate($hash);
      readingsBulkUpdate( $hash, "plan_error", "Error HTML::TableExtract failed" );
      readingsEndUpdate( $hash, 1 );

      return undef;
    }

    readingsBeginUpdate($hash);

    for($i=1; $i<=3; $i++) {

       my ($d_time, $a_time, $d_delay, $a_delay, $change, $duration, $prod, $price) = split(";", $planrow[$i]);

       $change = "" unless(defined($change));
       $duration = "" unless(defined($duration));
       $prod = "" unless(defined($prod));
       $price = "" unless(defined($price));

       Log3 $name, 4, "DBPlan ($name) - Timetable: $d_time - $a_time - $d_delay - $a_delay - $change - $duration - $prod - $price";

       readingsBulkUpdate( $hash, "plan_departure_$i", $d_time ) if(trim($d_time) ne "");
       readingsBulkUpdate( $hash, "plan_arrival_$i", $a_time ) if(trim($a_time) ne "");

       readingsBulkUpdate( $hash, "plan_connection_$i", $prod ) if(trim($prod) ne "");

       # readingsBulkUpdate( $hash, "plan_departure_delay_$i", $d_delay ) if(trim($d_delay) ne "");
       # readingsBulkUpdate( $hash, "plan_arrival_delay_$i", $a_delay ) if(trim($a_delay) ne "");

       readingsBulkUpdate( $hash, "plan_travel_duration_$i", $duration ) if(trim($duration) ne "");
       readingsBulkUpdate( $hash, "plan_travel_change_$i", $change ) if(trim($change) ne "");

       readingsBulkUpdate( $hash, "travel_price_$i", $price) if(trim($price) ne "");

       ##################################################################################
       # Parsing travel notes (notifications)
       # http://www.img-bahn.de/v/1504/img/achtung_17x19_mitschatten.png
       $pattern = '\<img src=".*?img\/(.*?)_.*?"\ \/\>\<\/a\>';
       if ($plan[$i] =~ m/$pattern/s) {
         readingsBulkUpdate( $hash, "travel_note_$i", $1) if(trim($1) ne "");
       #  readingsBulkUpdate( $hash, "plan_departure_delay_$i", "Hinweise" )  if(trim($1) ne "");
       #  readingsBulkUpdate( $hash, "plan_arrival_delay_$i", "Hinweise" )  if(trim($1) ne "");
         Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: travel note for plan $i read successfully";
       } else {
         Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: no travel note for plan $i found";
       }

       ##################################################################################
       # Parsing URL for further informations about travel notes (notifications)
       $pattern = '\<a href="(.*?)amp\;"\>';
       if ($plan[$i] =~ m/$pattern/s) {
          $notelink = $1;
          $notelink =~ s/amp\;//g;
          $notelink =~ s/details=opened.*?yes&/detailsVerbund=opened!/g;
          Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: travel note URL for plan $i: $notelink";
          readingsBulkUpdate( $hash, "travel_note_link_$i", $notelink)  if(trim($notelink) ne "");
       } else {
          Log3 $name, 4, "DBPlan ($name) - DBPlan_Parse_Timetable: no travel note URL for plan $i found";
       }

    } #end for
    readingsEndUpdate( $hash, 1 );

    ##################################################################################
    # First call of recursiv call of URL for further informations about travel notes (notifications)
    $hash->{note_index} = $i-1;
    $hash->{url}        = ReadingsVal($name, "travel_note_link_$hash->{note_index}", "");
    $hash->{callback}   = \&DBPlan_Parse_Travel_Notes;
    $hash->{noshutdown} = AttrVal($name, "dbplan-remote-noshutdown", 1);
    $hash->{timeout}    = AttrVal($name, "dbplan-remote-timeout", 5);
    $hash->{loglevel}   = AttrVal($name, "dbplan-remote-loglevel", 4);

    Log3 $name, 4, "DBPlan ($name) - DB notes ($hash->{note_index}): next getting $hash->{url}";

    HttpUtils_NonblockingGet($hash);

    return undef;
}

#####################################
# replaces all HTML entities to their utf-8 counter parts.
# c3 bc = ü
# c3 9f = ß
# c3 b6 = ö
# c3 a4 = ä
# c3 84 = Ä
# c3 96 = Ö
# c3 9c = Ü
# c2 ab = "
# c2 bb = "
# e2 80 = ""
# c2 ad = -
#

sub DBPlan_html2txt($)
{

    my ($string) = @_;

    $string =~ s/&nbsp;/ /g;
    $string =~ s/&amp;/&/g;
    $string =~ s/(\xe4|\xc3\xa4|&auml;|\\u00e4|\\u00E4|&#228;)/ÃƒÂ¤/g;
    $string =~ s/(\xc4|\xc3\x84|&Auml;|\\u00c4|\\u00C4|&#196;)/Ãƒâ€ž/g;
    $string =~ s/(\xf6|\xc3\xb6|&ouml;|\\u00f6|\\u00F6|&#246;)/ÃƒÂ¶/g;
    $string =~ s/(\xd6|\xc3\x96|&Ouml;|\\u00d6|\\u00D6|&#214;)/Ãƒâ€“/g;
    $string =~ s/(\xfc|\xc3\xbc|&uuml;|\\u00fc|\\u00FC|&#252;)/ÃƒÂ¼/g;
    $string =~ s/(\xdc|\xc3\x9c|&Uuml;|\\u00dc|\\u00DC|&#220;)/ÃƒÅ“/g;
    $string =~ s/(\xdf|\xc3\x9f|&szlig;|&#223;)/ÃƒÅ¸/g;
    $string =~ s/<.+?>//g;
    $string =~ s/(^\s+|\s+$)//g;

    return trim($string);

}

sub DBPlan_html2uml($)
{

    my ($string) = @_;

    $string =~ s/&nbsp;/ /g;
    $string =~ s/&amp;/&/g;
    $string =~ s/(\xe4|\xc3\xa4|&auml;|\\u00e4|\\u00E4|&#228;)/ä/g;
    $string =~ s/(\xc4|\xc3\x84|&Auml;|\\u00c4|\\u00C4|&#196;)/Ä/g;
    $string =~ s/(\xf6|\xc3\xb6|&ouml;|\\u00f6|\\u00F6|&#246;)/ö/g;
    $string =~ s/(\xd6|\xc3\x96|&Ouml;|\\u00d6|\\u00D6|&#214;)/Ö/g;
    $string =~ s/(\xfc|\xc3\xbc|&uuml;|\\u00fc|\\u00FC|&#252;)/ü/g;
    $string =~ s/(\xdc|\xc3\x9c|&Uuml;|\\u00dc|\\u00DC|&#220;)/Ü/g;
    $string =~ s/(\xdf|\xc3\x9f|&szlig;|&#223;)/ß/g;
    $string =~ s/<.+?>//g;
    $string =~ s/(^\s+|\s+$)//g;

    return trim($string);

}

# UTF8
sub DBPlan_decode($) {
  my($text) = @_;  
  $text =~ s/ä/Ã¤/g;
  $text =~ s/Ä/Ã„/g;
  $text =~ s/ö/Ã¶/g;
  $text =~ s/Ö/Ã/g;
  $text =~ s/ü/Ã¼/g;
  $text =~ s/Ü/Ãœ/g;
  $text =~ s/ß/ÃŸ/g;
  $text =~ s/´/Â´/g;
  $text =~ s/"/Â„/g;  
  return $text;
}

#####################################
# loads the stations from file
sub DBPlan_loadStationFile($;$)
{
  my ($hash, $file) = @_;

  my @stationfile;
  my @tmpline;
  my $name = $hash->{NAME};
  my $err;
  $file = AttrVal($hash->{NAME}, "dbplan-station-file", "") unless(defined($file));

  if($file ne "" and -r $file)
  { 
     delete($hash->{helper}{STATIONFILE}) if(defined($hash->{helper}{STATIONFILE}));
     delete($hash->{helper}{STATION_NAMES}) if(defined($hash->{helper}{STATION_NAMES}));
  
     Log3 $hash->{NAME}, 3, "DBPlan ($name) - loading station file $file";
        
     ($err, @stationfile) = FileRead($file);
        
     unless(defined($err) and $err)
     {      
       foreach my $line (@stationfile)
       {
         if(not $line =~ /^\s*$/)
         {
           chomp $line;

           $line =~ s/\n|\r//;

           Log3 $name, 5, "DBPlan ($name) - $line " . $tmpline[6];

           @tmpline = split(";", $line);

           if(@tmpline >= 2)
           {
             $hash->{helper}{STATION_NAMES}{$tmpline[0]} = $tmpline[6];
           }
         }
       }

       my $count_stations = scalar keys %{$hash->{helper}{STATION_NAMES}};
       Log3 $name, 2, "DBPlan ($name) - read ".($count_stations > 0 ? $count_stations : "no")." station".($count_stations == 1 ? "" : "s")." from station file"; 
    }
    else
    {
      Log3 $name, 3, "DBplan ($name) - could not open station file: $err";
    }
  }
  else
  {
    Log3 $name, 3, "DBPlan ($name) - unable to access station file: $file";
    return ("unable to access station file: $file");
  }
}


#####################################
# only for testing regular expressions
sub RegExTest()
{
#   my $test = '<h1>Fehler</h1> <div class="haupt bline"> Sehr geehrte Kundin, sehr geehrter Kunde,<br /><br /> Start/Ziel/Via oder &#228;quivalente Bahnh&#246;fe sind mehrfach vorhanden oder identisch. <br />Wir bitten Sie, Ihre Anfrage mit ge&#228;nderten Eingaben zu wiederholen. <br /><span class="bold"><br />Vielen Dank! <br />Ihr Team von www.bahn.de</span><br /> <br />Code: H9380<br /> </div> <div class="bline"> <a href="http://reiseauskunft.bahn.de/bin/detect.exe/dox?" ';

   my $test = ReadingsVal("DB_Test", "Notes_HTML_1", "none");

   my $pattern = '';

   $pattern = '"rline.haupt.stationDark.routeStart".style="."\>.\<span.class="bold"\>(.*?)\<\/span\>';

   if ($test =~ m/$pattern/s) {
      my $error_text = DBPlan_html2txt($1);
      return ("$1 \n\n$2 \n\n$3");
   }

   return ("Kein Ergebnis: $test");
}

1;

=pod
=begin html

<a name="DBPlan"></a>
<h3>DBPlan</h3>

<ul>
	The module fetches from the info page of the DB <http://reiseauskunft.bin.de/bin/query.exe/dox?S=departure&Z=destination&start=1&rt=1>
       up-to-date information on a specified connection and stores it in Fhem readings.
       The file with the IBNR codes and stations of Deutsche Bahn can be download at http://www.michaeldittrich.de/ibnr.

	<br><br>
	<b>Prerequisites</b>
	<ul>
		<br>
		<li>
			This Module uses the non blocking HTTP function HttpUtils_NonblockingGet provided by FHEM's HttpUtils in a new Version published in December 2013.<br>
			If the module is not already present in your Fhem environment, please update FHEM via the update command.<br>
		</li>
		
	</ul>
	<br>
       State will show the device status (DevState): 
	<ul>
		<li><b>initialized</b></li>
			the device is defined, but no successfully requests and parsing has been done<br>
                     this state will also be set when changing from <inactiv> to <activ> and <disabled> to <enabled><br>
		<li><b>active</b></li>
			the device is working<br>
		<li><b>stopped</b></li>
			the device timer has been stopped. A reread is possibel<br>
		<li><b>disabled</b></li>
			the device is disabled.<br>

	</ul>
	<br>

	<a name="DBPlandefine"></a>
	<b>Define</b>
	<ul>
		<br>
		<code>define &lt;name&gt; DBPlan &lt;Refresh interval in seconds [time offset in minutes]&gt;</code>
		<br><br>
		The module connects to the given URL every Interval seconds and then parses the response. If time_offset is
                defined, the moudules uses the actual time + time_offset as start point<br>
		<br>
		Example:<br>
		<br>
		<ul><code>define DBPlan_Test DBPlan 60</code></ul>
	</ul>
	<br>

	<a name="DBPlanconfiguration"></a>
	<b>Configuration of DBPlan</b><br><br>
	<ul>
		Example for a timetable query:<br><br>
		<ul><code>
                   attr DB_Test dbplan_station  K�ln-Weiden West
                   attr DB_Test dbplan_destination K�ln HBF
                   attr DB_Test room OPNV
		</code></ul>
	</ul>
	<br>

	<a name="DBPlanset"></a>
	<b>Set-Commands</b><br>
	<ul>
		<li><b>interval</b></li>
			set new interval time in seconds for parsing the DB time table<br>
		<li><b>timeOffset</b></li>
			Start of search: actual time plus time_offset.<br>
		<li><b>reread</b></li>
			reread and parse the DB time table. Only active, if not DevState: disabled<br>
		<li><b>stop</b></li>
			stop interval timer, only active if DevState: active<br>
		<li><b>start</b></li>
			restart interval timer, only active if DevState: stopped<br>
	</ul>
	<br>
	<a name="DBPlanget"></a>
	<b>Get-Commands</b><br>
	<ul>
		<li><b>PlainText</b></li>
			the informations will be shown as plain text<br>
		<li><b>searchStation</b></li>
			search for a german DB Station. Without search pattern all stations will be shown.<br>
	</ul>
	<br>

	<a name="DBPlanattr"></a>
	<b>Attributes</b><br><br>
	<ul>
		<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
		<br>
		<li><b>dbplan_station</b></li>
			place of departure<br>
		<li><b>dbplan_destination</b></li>
			place of destination<br>
		<li><b>dbplan_via_1</b></li>
			DB first via station<br>
		<li><b>dbplan_via_2</b></li>
			DB second via station<br>
		<li><b>dbplan_journey_prod</b></li>
			DB travel products like: ICE<br>
		<li><b>dbplan_journey_opt</b></li>
			DB journey options like: direct connection<br>
		<li><b>dbplan_tariff_class</b></li>
			DB tariff class: 1 or 2 class<br>
		<li><b>dbplan_board_type</b></li>
			DB board type: departure or arrival (depart / arrive)<br>
		<li><b>dbplan_delayed_Journey</b></li>
			DB delayed journey: on or off<br>
		<li><b>dbplan_max_Journeys</b></li>
			Number of displayed train connections in the station view.<br>
		<li><b>dbplan_reg_train</b></li>
			The train designation, e.g. S for everything S- and streetcars, ICE all ICE or ICE with train number.<br>
		<li><b>dbplan_travel_date</b></li>
			Define the date of travel in dd.mm.yy. Default: actual date.<br>
		<li><b>dbplan_travel_time</b></li>
			Define the time of travel in hh:mm. Default: actual time.<br>
		<li><b>dbplan_addon_options</b></li>
			extended options like discribed in the api document: <li><a http://webcache.googleusercontent.com/search?q=cache:wzb_OlIUCBQJ:www.geiervally.lechtal.at/sixcms/media.php/1405/Parametrisierte%2520%25DCbergabe%2520Bahnauskunft(V%25205.12-R4.30c,%2520f%25FCr.pdf+&cd=3&hl=de&ct=clnk&gl=de
">Parametrisierte ÃƒÅ“bergabe Bahnauskunft</a></li><br>
              <br>
		<li><b>Attributes controlling the behavior:</b></li>
		<li><b>dbplan-disable</b></li>
			If set to 1 polling of DB Url will be stopped, setting to 0 or deleting will activate polling<br>
		<li><b>dbplan-default-char</b></li>
			Define a string which will be displayed if no information is available. Defaultstring: "none"<br>
			When defined the special string "delete" the raeding will not be filled and is not available since an information excists<br>
			When defined the special string "nochar" the raeding will be filled with " "<br>
		<li><b>dbplan-tabel-headers</b></li>
			internal attribute to change the header information used by HTML::TableExtract<br>
		<li><b>dbplan-station-file</b></li>
			Directory and name of the station table to be used: /opt/fhem/FHEM/deutschland_bhf.csv<br>
			This table is to be used as a help for the search for railway stations and has no other function in the module.<br>
		<li><b>dbplan-base-type</b></li>
			Select whether a station table (table) or a timetable (plan) display is to be generated<br>
              <br>
		<li><b>HTTPMOD attributes, have a look at the documentation</b></li>
		<li><b>dbplan-remote-timeout</b></li>
		<li><b>dbplan-remote-noshutdown</b></li>
		<li><b>dbplan-remote-loglevel</b></li>
	</ul>
       <br>
	<a name="DBPlanReadings"></a>
	<b>Readings</b><br><br>
	<ul>
		<li><a href="#internalReadings">internalReadings</a></li>
		<br>
		<li><b>departure_(1..3)</b></li>
			time of departure<br>
		<li><b>arrival_(1..3)</b></li>
			time of arrival<br>
		<li><b>connection_(1..3)</b></li>
			type of connection<br>
		<li><b>departure_delay_(1..3)</b></li>
			delay time for departure<br>
		<li><b>arrival_delay_(1..3)</b></li>
			delay time for arrival<br>
              <br>
		<li><b>travel_departure_(1..3)</b></li>
			informations about the departure and the plattform, if available<br>
		<li><b>travel_destination_(1..3)</b></li>
			informations about the destination and the plattform, if available<br>
		<li><b>travel_duration_(1..3)</b></li>
			travel duration time<br>
		<li><b>travel_change_(1..3)</b></li>
			travel plattform changings<br>
		<li><b>travel_price_(1..3)</b></li>
			travel price in EUR<br>
              <br>
		<li><b>travel_error_(1..3)</b></li>
			error information when calling the note url<br>
		<li><b>travel_note_(1..3)</b></li>
			travel note for travel plan<br>
		<li><b>travel_note_link_(1..3)</b></li>
			travel note link for further informations<br>
		<li><b>travel_note_text_(1..3)</b></li>
			travel note text<br>
	</ul>
</ul>

=end html

=begin html_DE

<a name="DBPlan"></a>
<h3>DBPlan</h3>

<ul>
	Das Modul holt von der Infoseite der DB <http://reiseauskunft.bahn.de/bin/query.exe/dox?S=departure&Z=destination&start=1&rt=1>
       aktuelle Informationen zu einer angegeben Verbindung und legt sie in Fhem readings ab.
       Die Datei mit den IBNR-Codes und Stationen der Deutschen Bahn kann unter http://www.michaeldittrich.de/ibnr abgerufen werden.

	<br><br>
	<b>Prerequisites</b>
	<ul>
		<br>
		<li>
			Dieses Modul verwendet die nicht blockierende HTTP-Funktion HttpUtils_NonblockingGet von FHEM's HttpUtils in der aktuellen Version.<br>
                     Falls das Modul noch nicht in Ihrer Fhem-Umgebung vorhanden ist, aktualisieren Sie bitte FHEM �ber den Update Befehl.<br>
		</li>
		
	</ul>
	<br>
       Der device status (DevState): 
	<ul>
		<li><b>initialized</b></li>
			Das Device ist definiert, aber es wurde keine erfolgreichen Anfragen und Analysen durchgef�hrt<br>
                     Dieser Zustand wird auch beim Wechsel von <inactiv> auf <activ> und <disabled> auf <enabled> gesetzt<br>
		<li><b>active</b></li>
			Das Device arbeitet<br>
		<li><b>stopped</b></li>
			Der Device Time wurde angehalten. Ein reread ist jedoch m�glich<br>
		<li><b>disabled</b></li>
			Das Device wurde deaktiviert.<br>
	</ul>
	<br>

	<a name="DBPlandefine"></a>
	<b>Define</b>
	<ul>
		<br>
		<code>define &lt;name&gt; DBPlan &lt;Refresh interval in seconds [time offset in minutes]&gt;</code>
		<br><br>
              Das Modul holt nach angegebenen "Intervall"-Sekunden �ber die DB URL die Fahrpl�ne. Ist time_offset definiert werden
              die Fahrpl�ne f�r die aktuelle Zeit plus Offset in Minuten gelesen.<br>
		<br>
		Example:<br>
		<br>
		<ul><code>define DBPlan_Test DBPlan 60</code></ul>
	</ul>
	<br>

	<a name="DBPlanconfiguration"></a>
	<b>Konfiguration von DBPlan</b><br><br>
	<ul>
		Beispiel f�r eine Fahrplanabfrage:<br><br>
		<ul><code>
                   attr DB_Test dbplan_station  K�ln-Weiden West
                   attr DB_Test dbplan_destination K�ln HBF
                   attr DB_Test room OPNV
		</code></ul>
	</ul>
	<br>

	<a name="DBPlanset"></a>
	<b>Set-Commands</b><br>
	<ul>
		<li><b>interval</b></li>
			setzen einer anderen Intervallzeit f�r das Holen und Parsen der DB Informationen<br>
		<li><b>timeOffset</b></li>
			Start der Suche: aktuelle Zeit plus time_offset.<br>
		<li><b>reread</b></li>
			Holen und Parsen der DB Informationen. Nur aktiv, wenn kein Status: disabled<br>
		<li><b>stop</b></li>
			Stoppt den Timer. Nur aktiv, wenn Status: active<br>
		<li><b>start</b></li>
			Neustart des Timers. Nur aktiv, wenn Status: stopped<br>
	</ul>
	<br>
	<a name="DBPlanget"></a>
	<b>Get-Commands</b><br>
	<ul>
		<li><b>PlainText</b></li>
			Die ermittelten Informationen werden als "plain Text" ausgegeben<br>
		<li><b>searchStation</b></li>
			suche in der Bahnhofstabelle. Wird kein Suchbegriff eingegen, werden alle Bahnh�fe angezeigt.<br>
	</ul>
	<br>

	<a name="DBPlanattr"></a>
	<b>Attributes</b><br><br>
	<ul>
		<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
		<br>
		<li><b>dbplan_station</b></li>
			Abfahrtsbahnhof / Haltestelle<br>
		<li><b>dbplan_destination </b></li>
			Ankunftsbahnhof / Haltestelle<br>
		<li><b>dbplan_via_1 </b></li>
			1. Zwischenhalt in Bahnhof / Haltestelle<br>
		<li><b>dbplan_via_2 </b></li>
			2. Zwischenhalt in Bahnhof / Haltestelle<br>
		<li><b>dbplan_journey_prod </b></li>
			Verkehrsmittel, wie z.B.: ICE, Bus, Stra�enbahn<br>
		<li><b>dbplan_journey_opt </b></li>
			Reiseoptionen wie z.B.: direct connection<br>
		<li><b>dbplan_tariff_class </b></li>
			1. oder 2. Klasse<br>
		<li><b>dbplan_board_type </b></li>
			Fahrplansuche bzw. Bahnhofsanzeige f�r Abfahrts- oder Ankunftszeit (depart / arrive).<br>
		<li><b>dbplan_delayed_Journey </b></li>
			Bei off werden nur p�nktliche Verbindungen angezeigt.<br>
		<li><b>dbplan_max_Journeys </b></li>
			Anzahl der angezeigten Zugverbindungen in der Bahnhofsansicht.<br>
		<li><b>dbplan_reg_train </b></li>
			die Zugbezeichnung, z.B. S f�r alles was S- und Stra�enbahnen angeht, ICE alle ICE oder ICE mit Zugnummer. Usw.<br>
		<li><b>dbplan_travel_date </b></li>
			Reisedatum in der Angabe: dd.mm.yy<br>
		<li><b>dbplan_travel_time </b></li>
			Abfahtrtszeit in der Angabe: hh.mm<br>
		<li><b>dbplan_addon_options </b></li>
			weitere Optionen, wie sie im API-Dokument der DB beschrieben sind.<br>
              <br>
		<li><b>Steuernde Attribute:</b></li>
		<li><b>dbplan-disable </b></li>
			Device aktivieren / deaktivieren (s. auch FHEM-Doku)<br>
		<li><b>dbplan-default-char </b></li>
			Hinweis, der angezeigt wird, wenn keine Information f�r ein reading zur Verf�gung steht.<br>
			- "none" ist der Standardhinweis.<br> 
			Sofern folgende spezielle Eintr�ge gemacht werden:
			- "delete" nicht genutzte readings werden auch nicht angezeigt.<br>
			- "nochar" das Reading wird mit leerem Inhalt angezeigt.<br>
		<li><b>dbplan-tabel-headers </b></li>
			internes Attribut um die Spaltenbezeichnungen f�r HTML::TableExtract<br>
		<li><b>dbplan-station-file </b></li>
			Pfad zur Bahnhofstabelle der Deutschen Bahn (evtl. nicht vollst�ndig). F�r F�r andere Verkehrsunternehmen liegen keine Tabellen vor.<br>
			Diese Tabelle ist als Hilfe f�r die Suche nach Bahnh�fen anzusehen und hat keine weitere Funktion im Modul.<br>
		<li><b>dbplan-base-type </b></li>
			Anzeige als Bahnhofstabelle (table) oder Verbindungsinformation (plan)<br>
              <br>
		<li><b>HTTPMOD Attribute, siehe entsprechende Doku</b></li>
		<li><b>dbplan-remote-timeout</b></li>
		<li><b>dbplan-remote-noshutdown</b></li>
		<li><b>dbplan-remote-loglevel</b></li>

	</ul>
       <br>
	<a name="DBPlanReadings"></a>
	<b>Readings</b><br><br>
	<ul>
		<li><a href="#internalReadings">internalReadings</a></li>
		<br>
		<li><b>departure_(1..3)</b></li>
			time of departure<br>
		<li><b>departure_(1..3) </b></li>
			Abfahrtszeit<br>
		<li><b>arrival_(1..3) </b></li>
			Ankunftszeit<br>
		<li><b>connection_(1..3) </b></li>
			Verbindungstyp<br>
		<li><b>departure_delay_(1..3) </b></li>
			Versp�tung in der Abfahrtszeit<br>
		<li><b>arrival_delay_(1..3) </b></li>
			Versp�tung in der Ankunftszeit<br>
              <br>
		<li><b>travel_note_(1..3) </b></li>
			Hinweise f�r die Verbindung<br>
		<li><b>travel_note_link_(1..3) </b></li>
			Link zu den weiteren Verbindungsinformationen<br>
		<li><b>travel_note_text_(1..3) </b></li>
			Verbindungshinweis<br>
		<li><b>travel_note_error_(1..3) </b></li>
			Fehlertext der Detailinformation<br>
              <br>
		<li><b>travel_duration_(1..3) </b></li>
			Reisezeit<br>
		<li><b>travel_departure_(1..3) </b></li>
			Informationen �ber den Abfahtsbahnhof und das Ankunftsgleis<br>
		<li><b>travel_destination_(1..3) </b></li>
			Informationen �ber den Zielbahnhof und das Ankunftsgleis<br>
		<li><b>travel_change_(1..3) </b></li>
			Anzahl der Umstiege<br>
		<li><b>travel_price_(1..3) </b></li>
			Fahrpreis<br>
	</ul>
</ul>

=end html_DE

=cut
