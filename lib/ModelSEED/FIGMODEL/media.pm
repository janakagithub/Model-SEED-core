#!/usr/bin/perl -w
########################################################################
# MEDIA OBJECT: An object that manages all access to the media object
# Author: Christopher Henry
# Author email: chenry@mcs.anl.gov
# Author affiliation: Mathematics and Computer Science Division, Argonne National Lab
# Date of module creation: 11/6/2011
########################################################################
use strict;
use warnings;
use File::Temp qw(tempfile);
use File::Path;
use File::Copy::Recursive;
use ModelSEED::globals;

package ModelSEED::FIGMODEL::media;

use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

extends 'ModelSEED::MooseDB::media' #So access to all database content comes through this subclass

has 'id' => (is => 'ro', isa => 'Str', required => 1);
has 'owner' => (is => 'ro', isa => 'Str', required => 1);

sub BUILD {
    my ($self,$params) = @_;
	$params = ModelSEED::utilities::ARGS($params,[],{});
}




=head3 create
Definition:
	FIGMODELmedia = FIGMODELmedia->create({
		filename => 
	});
Description:
	Creates a media formulation from a file or from a compound list
=cut
sub create {
	my ($self,$args) = @_;
	$args = $self->figmodel()->process_arguments($args,["id"],{
		filename => undef,
		compounds => undef,
		public => 1,
		owner => $self->figmodel()->user(),
		overwrite => 0,
        aerobic => 1,
	});
	my $mediaObj = $self->figmodel()->database()->sudo_get_object("media",{id => $args->{id}});
	if (defined($mediaObj)) {
		if ($args->{overwrite} == 0) {
			ModelSEED::utilities::ERROR("Media already exists, and overwrite flag was not set!");
		}
		my $rights = $self->figmodel()->database()->get_object_rights($mediaObj,"media");
		if (!defined($rights->{admin})) {
			ModelSEED::utilities::ERROR("No rights to alter media object");
		}
		$mediaObj->public($args->{public} || $mediaObj->public());
		$mediaObj->aerobic($args->{aerobic} || $mediaObj->aerobic());
		$mediaObj->owner($args->{owner} || $mediaObj->owner());
		$mediaObj->modificationDate(time());
	} else {
		$mediaObj = $self->figmodel()->database()->create_object("media",{
	    	public => $args->{public},
	    	id => $args->{id},
	    	aerobic => $args->{aerobic},
	    	owner => $args->{owner},
	    	creationDate => time(),
	    	modificationDate => time()
	    });
	}
	$self->{_ppo} = $mediaObj;
	$self->{_id} = $args->{id};
	if (defined($args->{filename})) {
		$self->loadPPOFromFile({filename => $args->{filename}});
	} elsif (defined($args->{compounds})) {
		$self->loadCompoundListToPPO({
			compounds => $args->{compounds},
			addUniversal => 0
		});
	} else {
		ModelSEED::utilities::ERROR("Cannot create media without either filename or compound list");
	}
	#Determining if media is aerobic
	if (defined($self->{_entities}->{cpd00007}) && $self->{_entities}->{cpd00007}->{maxFlux} > 0) {
		$self->{_ppo}->aerobic(1);
	}
	return $self;
}


=head3 loadCompoundsFromFile
Definition:
	Output = FIGMODELmedia->loadCompoundsFromFile({clear => 0/1});
	Output: {string:entity ID => {
		MEDIA => string,
		entity => string,
		type => string,
		concentration => float,
		maxFlux => float,
		minFlux => float
	}}
Description:
	Loads the media data from file
=cut
sub loadCompoundsFromFile {
	my ($self,$args) = @_;
	$args = $self->figmodel()->process_arguments($args,[],{
		filename => $self->filename()
	});
	delete $self->{_entities};
	my $list = $self->figmodel()->database()->load_single_column_file($args->{filename},"");
	ModelSEED::utilities::ERROR("Could not load file for media:".$args->{id}) if (!defined($list));
	my $headings = [split(/;/,$list->[0])];
	my $headingHash;
	for (my $i=0; $i < @{$headings}; $i++) {
		$headingHash->{$headings->[$i]} = $i;
	}
	if (!defined($headingHash->{VarName}) || !defined($headingHash->{VarType}) || !defined($headingHash->{VarCompartment}) || !defined($headingHash->{Min}) || !defined($headingHash->{Max})) {
		ModelSEED::utilities::ERROR("Media file invalid.");
	}
	for (my $i=1; $i < @{$list}; $i++) {
		my $temp = [split(/;/,$list->[$i])];
		if (@{$temp} >= 5 && $temp->[$headingHash->{VarName}] =~ m/cpd\d\d\d\d\d/ && $temp->[$headingHash->{VarCompartment}] eq "e") {
			if (!defined($self->{_entities}->{$temp->[$headingHash->{VarName}]})) {
				$self->{_entities}->{$temp->[$headingHash->{VarName}]} = {
					MEDIA => $self->id(),
					entity => $temp->[$headingHash->{VarName}],
					type => "COMPOUND",
					concentration => 0.001,
					maxFlux => 100,
					minFlux => -100
				}
			}
			if ($temp->[$headingHash->{VarType}] eq "DRAIN_FLUX") {
				$self->{_entities}->{$temp->[$headingHash->{VarName}]}->{maxFlux} = $temp->[$headingHash->{Max}];
				$self->{_entities}->{$temp->[$headingHash->{VarName}]}->{minFlux} = $temp->[$headingHash->{Min}];
			} elsif ($temp->[$headingHash->{VarType}] eq "CONC") {
				$self->{_entities}->{$temp->[$headingHash->{VarName}]}->{concentration} = 0.5*($temp->[$headingHash->{Min}]+$temp->[$headingHash->{Max}]);
			} elsif ($temp->[$headingHash->{VarType}] eq "LOG_CONC") {
				$self->{_entities}->{$temp->[$headingHash->{VarName}]}->{concentration} = exp(0.5*($temp->[$headingHash->{Min}]+$temp->[$headingHash->{Max}]));
			} 
		}
	} 
	return $self->{_entities};
}
=head3 loadCompoundsFromPPO
Definition:
	Output = FIGMODELmedia->loadCompoundsFromPPO({clear => 0/1});
	Output: {string:entity ID => {
		MEDIA => string,
		entity => string,
		type => string,
		concentration => float,
		maxFlux => float,
		minFlux => float
	}}
Description:
	Loads the media data from PPO database
=cut
sub loadCompoundsFromPPO {
	my ($self,$args) = @_;
	$args = $self->figmodel()->process_arguments($args,[],{});
	delete $self->{_entities};
	my $mediacpds = $self->figmodel()->database()->get_objects("mediacpd",{MEDIA=>$self->id()});
	for (my $i=0; $i < @{$mediacpds}; $i++) {
		$self->{_entities}->{$mediacpds->[$i]->entity()} = {
			MEDIA => $mediacpds->[$i]->MEDIA(),
			entity => $mediacpds->[$i]->entity(),
			type => $mediacpds->[$i]->type(),
			concentration => $mediacpds->[$i]->concentration(),
			maxFlux => $mediacpds->[$i]->maxFlux(),
			minFlux => $mediacpds->[$i]->minFlux()	
		}
	}
	return $self->{_entities};
}
=head3 loadPPOFromFile
Definition:
	{} = FIGMODELcompound->loadPPOFromFile({
	});
Description:
	Loads the compound data from file into PPO database
=cut
sub loadPPOFromFile {
	my ($self,$args) = @_;
	$args = $self->figmodel()->process_arguments($args,[],{
		filename => $self->filename()
	});
	my $data = $self->loadCompoundsFromFile({filename => $args->{filename}});
	my $oldObjs = $self->figmodel()->database()->get_objects("mediacpd", {MEDIA=>$self->id()});
	my %oldObjsById = map { $_->entity() => $_ } @$oldObjs;

	foreach my $id (keys(%{$data})) {
	    my $newObj = $oldObjsById{$id};
		if (defined($newObj)) {
			$newObj->concentration($data->{$id}->{concentration});
			$newObj->maxFlux($data->{$id}->{maxFlux});
			$newObj->minFlux($data->{$id}->{minFlux});
			delete $oldObjsById{$id};
		} else {
			$self->figmodel()->database()->create_object("mediacpd",$data->{$id});
		}
	}
	# delete compounds that are no longer associated with the media
	foreach my $obj (values %oldObjsById) {
	    $obj->delete();
	}
}
=head3 loadCompoundListToPPO
Definition:
	{} = FIGMODELcompound->loadCompoundListToPPO({
		compounds => [string]
	});
Description:
	Given a list of compounds, either find the media formulation with these compounds or create a new formulation
=cut
sub loadCompoundListToPPO {
	my ($self,$args) = @_;
	$args = $self->figmodel()->process_arguments($args,["compounds"],{
		id => $self->{_id},
		addUniversal => 0
	});
	my $cpdHash;
	if ($args->{addUniversal} == 1) {
		my $universalList = $self->figmodel()->config("Universal media compounds");
		for (my $i=0; $i < @{$universalList}; $i++) {
			$cpdHash->{$universalList->[$i]} = 1;	
		}
	}
	my $alsHash;
	for (my $i=0; $i < @{$args->{compounds}}; $i++) {
		if ($args->{compounds}->[$i] =~ m/cpd\d+$/) {
			$cpdHash->{$args->{compounds}->[$i]} = 1;
		} else {
			if (!defined($alsHash)) {
				my $cpdalss = $self->figmodel()->database()->get_objects("cpdals");
				for (my $i=0; $i < @{$cpdalss}; $i++) {
					$alsHash->{lc($cpdalss->[$i]->alias())}->{$cpdalss->[$i]->COMPOUND()} = 1;
				}
			}
			if (!defined($alsHash->{lc($args->{compounds}->[$i])})) {
				ModelSEED::utilities::WARNING("Compound ".$args->{compounds}->[$i]." not found in database");
			} else {
				my $hitList = [keys(%{$alsHash->{lc($args->{compounds}->[$i])}})];
				if (@{$hitList} > 1) {
					ModelSEED::utilities::WARNING("Multiple matches for ".$args->{compounds}->[$i].":".join(",",@{$hitList}));
				}
				$cpdHash->{$hitList->[0]} = 1;
			}
		}
	}
	foreach my $cpd (keys(%{$cpdHash})) {
		$self->figmodel()->database()->create_object("mediacpd",{
			MEDIA => $args->{id},
			concentration => 0.001,
			maxFlux => 100,
			minFlux => -100,
			type => "COMPOUND",
			entity => $cpd
		});
		$self->{_entities}->{$cpd} = {
			MEDIA => $args->{id},
			entity => $cpd,
			type => "COMPOUND",
			concentration => 0.001,
			maxFlux => 100,
			minFlux => -100	
		}
	}
}
=head3 createFindMedia
Definition:
	{} = FIGMODELcompound->createFindMedia({
		compounds => [string]
	});
Description:
	Given a list of compounds, either find the media formulation with these compounds or create a new formulation
=cut
sub createFindMedia {
	my ($self,$args) = @_;
	$args = $self->figmodel()->process_arguments($args,["compounds","id"],{
		owner => $self->figmodel()->user(),
		public => 0
	});
	my $universalList = $self->figmodel()->config("Universal media compounds");
	my $cpdHash;
	for (my $i=0; $i < @{$universalList}; $i++) {
		$cpdHash->{$universalList->[$i]} = 1;	
	}
	my $cpdalss = $self->figmodel()->database()->get_objects("cpdals");
	my $alsHash;
	for (my $i=0; $i < @{$cpdalss}; $i++) {
		$alsHash->{lc($cpdalss->[$i]->alias())}->{$cpdalss->[$i]->COMPOUND()} = 1;
	}
	for (my $i=0; $i < @{$args->{compounds}}; $i++) {
		if ($args->{compounds}->[$i] !~ m/cpd\d\d\d\d\d/) {
			if (!defined($alsHash->{lc($args->{compounds}->[$i])})) {
				ModelSEED::utilities::WARNING("Compound ".$args->{compounds}->[$i]." not found in database");
				return undef;
			}
			my $hitList = [keys(%{$alsHash->{lc($args->{compounds}->[$i])}})];
			if (@{$hitList} > 1) {
				ModelSEED::utilities::WARNING("Multiple matches for ".$args->{compounds}->[$i].":".join(",",@{$hitList}));
			}
			$args->{compounds}->[$i] = $hitList->[0];
		}
		$cpdHash->{$args->{compounds}->[$i]} = 1;
	};
	my $mediaHash = $self->figmodel()->database()->get_object_hash({
		type => "mediacpd",
		attribute => "MEDIA",
		useCache => 1
	});
	my $mediaCpdHash;
	foreach my $media (keys(%{$mediaHash})) {
		my $mediaList;
		for (my $i=0; $i < @{$mediaHash->{$media}}; $i++) {
			push(@{$mediaList},$mediaHash->{$media}->[$i]->entity());
		}
		$mediaCpdHash->{join(";",sort(@{$mediaList}))} = $media;
	}
	if (defined($mediaCpdHash->{join(";",sort(keys(%{$cpdHash})))})) {
		$self->{_id} = $mediaCpdHash->{join(";",sort(keys(%{$cpdHash})))};
		if (length($self->ppo()->aliases()) > 0) {
			my $temp = [split(/\|/,$self->ppo()->aliases())];
			my $tempHash;
			for (my $i=0; $i < @{$temp}; $i++) {
				$tempHash->{$temp->[$i]} = 1;
			}
			$tempHash->{$args->{id}} = 1;
			$self->ppo()->aliases(join("|",keys(%{$tempHash})));
		} else {
			$self->ppo()->aliases($args->{id});
		}
		print "Media already exists!\n";
		return $self;
	}
	#Media does not exist yet: checking if ID is unique
	my $aerobic = 0;
	if (defined($cpdHash->{cpd00007})) {
		$aerobic = 1;
	}
	my $ppo = $self->figmodel()->database()->get_object("media",{id => $args->{id}});
	if (defined($ppo)) {
		my $index = 0;
		while (defined($self->figmodel()->database()->get_object("media",{id => $args->{id}."_".$index}))) {
			$index++;
		}
		$args->{id} = $args->{id}."_".$index;
	}
	$self->{_ppo} = $self->figmodel()->database()->create_object("media",{
		id => $args->{id},
		owner => $args->{owner},
		modificationDate => time(),
		creationDate => time(),
		aerobic => $aerobic,
		public => $args->{public}
	});
	foreach my $cpd (keys(%{$cpdHash})) {
		$self->figmodel()->database()->create_object("mediacpd",{
			MEDIA => $args->{id},
			concentration => 0.001,
			maxFlux => 100,
			minFlux => -100,
			type => "COMPOUND",
			entity => $cpd
		});
		$self->{_entities}->{$cpd} = {
			MEDIA => $args->{id},
			entity => $cpd,
			type => "COMPOUND",
			concentration => 0.001,
			maxFlux => 100,
			minFlux => -100	
		}
	}
	$self->createMediaFile();
	return $self;
}
=head3 createMediaFile
Definition:
	{} = FIGMODELcompound->createMediaFile();
Description:
	Creates a file for the media condition from the _entities or PPO
=cut
sub createMediaFile {
	my ($self,$args) = @_;
	$args = $self->figmodel()->process_arguments($args,[],{});
	if (!defined($self->{_entities})) {
		$self->loadCompoundsFromPPO();	
	}
	if (!defined($self->{_entities})) {
		ModelSEED::utilities::ERROR("Could not find compounds for media");	
	}
	my $output = ["VarName;VarType;VarCompartment;Min;Max"];
	foreach my $cpd (keys(%{$self->{_entities}})) {
		if ($self->{_entities}->{$cpd}->{type} eq "COMPOUND") {
			push(@{$output},$self->{_entities}->{$cpd}->{entity}
				.";DRAIN_FLUX;e"
				.";".$self->{_entities}->{$cpd}->{minFlux}
				.";".$self->{_entities}->{$cpd}->{maxFlux}
			);
		}
	}
	$self->figmodel()->database()->print_array_to_file($self->filename(),$output);
}
=head3 printDatabaseTable
Definition:
	undef = FIGMODELreaction->printDatabaseTable({
		filename => string
	});
Description:
=cut
sub printDatabaseTable {
	my ($self,$args) = @_;
	$args = $self->figmodel()->process_arguments($args,[],{
		printList => [$self->id()],
		filename => $self->figmodel()->config("media data filename")->[0]
	});
	if (!defined($args->{printList}->[0])) {
		$args->{printList}->[0] = "ALL";
	}
	my $objs = $self->figmodel()->database()->get_objects("media");
	if ($args->{printList}->[0] eq "ALL") {
		for (my $i=0; $i < @{$objs}; $i++) {
			$args->{printList}->[$i] = $objs->[$i];
		}
	} else {
		for (my $i=0; $i < @{$args->{printList}}; $i++) {
			my $found = 0;
			for (my $j=0; $j < @{$objs}; $j++) {
				if ($objs->[$j]->id() eq $args->{printList}->[$i]) {
					$args->{printList}->[$i] = $objs->[$j];
					$found = 1;
					last;
				}
			}
			if ($found == 0) {
				for (my $j=0; $j < @{$objs}; $j++) {
					my $array = [split(/\|/,$objs->[$j]->aliases())];
					for (my $k=0; $k < @{$array}; $k++) {
						if ($array->[$k] eq $args->{printList}->[$i]) {
							$args->{printList}->[$i] = $objs->[$j];
							$found = 1;
							last;
						}
					}	
				}
			}
			if ($found == 0) {
				$args->{printList}->[$i] = undef;
			}
		}
	}
	my $output = ["ID\tNAMES\tVARIABLES\tTYPES\tMAX\tMIN\tCOMPARTMENTS"];
	my $parameters = {};
	if (@{$args->{printList}} == 1) {
		$parameters->{MEDIA} = $args->{printList}->[0]->id();
	}
	my $mediacpds = $self->figmodel()->database()->get_object_hash({
		type => "mediacpd",
		attribute => "MEDIA",
		useCache => 1,
		parameters => $parameters
	});
	for (my $i=0; $i < @{$args->{printList}}; $i++) {
		if (defined($args->{printList}->[$i])) {
			my $line = $args->{printList}->[$i]->id()."\t".$args->{printList}->[$i]->id();
			if (defined($args->{printList}->[$i]->aliases()) && length($args->{printList}->[$i]->aliases()) > 0) {
				$line .= "|".$args->{printList}->[$i]->aliases();
			}
			$line .= "\t";
			my $types = "";
			my $maxes = "";
			my $mins = "";
			my $comps = "";
			if (defined($mediacpds->{$args->{printList}->[$i]->id()})) {
				for (my $j=0; $j < @{$mediacpds->{$args->{printList}->[$i]->id()}}; $j++) {
					if ($j > 0) {
						$line .= "|";
						$types .= "|";
						$maxes .= "|";
						$mins .= "|";
						$comps .= "|";
					}
					$line .= $mediacpds->{$args->{printList}->[$i]->id()}->[$j]->entity();
					if ($mediacpds->{$args->{printList}->[$i]->id()}->[$j]->type() eq "COMPOUND") {
						$types .= "DRAIN_FLUX";
					}
					$maxes .= $mediacpds->{$args->{printList}->[$i]->id()}->[$j]->maxFlux();
					$mins .= $mediacpds->{$args->{printList}->[$i]->id()}->[$j]->minFlux();
					$comps .= "e";
				}
			}
			push(@{$output},$line."\t".$types."\t".$maxes."\t".$mins."\t".$comps);
		}
	}
	$self->figmodel()->database()->print_array_to_file($args->{filename},$output);
}

1;
