#!/bin/bash

nevt=${1}
echo "%MSG-MG5 number of events requested = $nevt"

rnum=${2}
echo "%MSG-MG5 random seed used for the run = $rnum"

ncpu=${3}
echo "%MSG-MG5 number of cpus = $ncpu"

LHEWORKDIR=`pwd`

use_gridpack_env=true
if [ -n "$4" ]
  then
  use_gridpack_env=$4
fi

if [ "$use_gridpack_env" = true ]
  then
    if [ -n "$5" ]
      then
        scram_arch_version=${5}
      else
        scram_arch_version=SCRAM_ARCH_VERSION_REPLACE
    fi
    echo "%MSG-MG5 SCRAM_ARCH version = $scram_arch_version"

    if [ -n "$6" ]
      then
        cmssw_version=${6}
      else
        cmssw_version=CMSSW_VERSION_REPLACE
    fi
    echo "%MSG-MG5 CMSSW version = $cmssw_version"
    export VO_CMS_SW_DIR=/cvmfs/cms.cern.ch
    source $VO_CMS_SW_DIR/cmsset_default.sh
    export SCRAM_ARCH=${scram_arch_version}
    scramv1 project CMSSW ${cmssw_version}
    cd ${cmssw_version}/src
    eval `scramv1 runtime -sh`
fi
cd $LHEWORKDIR

# test if the current file system allow setting folder permission to read-only.
succ_setreadonly=true
mkdir testpermit
if fs listacl &>/dev/null; then
    # AFS system detected. Use "fs sa" rather than "chmod" to set permission
    echo "[MT] AFS system detected"
    fs sa -dir testpermit -acl ${USER} read
    if touch testpermit/newfile &>/dev/null; then succ_setreadonly=false; fi
    fs sa -dir testpermit -acl ${USER} all
else
    chmod -w testpermit
    if touch testpermit/newfile &>/dev/null; then succ_setreadonly=false; fi
    chmod +w testpermit
fi
rm -r testpermit
if [ $succ_setreadonly = false ]; then
    echo "[MT] Warning: failed to set a folder to read-only mode with the current file system. Will use the normal mode and run with single core instead. Note that the script only works under directories in ordinary Unix file system or AFS system, while you are probably using other systems, e.g. EOS. This should NOT happen in a CRAB job. Please report the error if you see this in a CRAB job."
fi

if fs listacl &>/dev/null; then
    fs sa -dir process/madevent -acl ${USER} all
else
    chmod +w process/madevent
fi
cd process

#make sure lhapdf points to local cmssw installation area
LHAPDFCONFIG=`echo "$LHAPDF_DATA_PATH/../../bin/lhapdf-config"`

echo "lhapdf = $LHAPDFCONFIG" >> ./madevent/Cards/me5_configuration.txt
# echo "cluster_local_path = `${LHAPDFCONFIG} --datadir`" >> ./madevent/Cards/me5_configuration.txt
#To overcome problem of taking toomanythreads
#set "nb_core = 2" will not force MG to run on multicore in the gridpack mode. But we keep the settings
#if [ "$ncpu" -gt "1" ]; then
echo "run_mode = 2" >> ./madevent/Cards/me5_configuration.txt
echo "nb_core = $ncpu" >> ./madevent/Cards/me5_configuration.txt
#fi

function event_generate_per_thread () {

# number of event to generate and seed in this thread
thd=${1}
nevt=${2}
rnum=${3}

if [ -d thread${thd} ]; then
    rm -r thread${thd}
fi
mkdir thread${thd}
cd thread${thd}
#########################################
# FORCE IT TO PRODUCE EXACTLY THE REQUIRED NUMBER OF EVENTS
#########################################

# define max event per iteration as 5000 if n_evt<45000 or n_evt/9 otherwise
max_events_per_iteration=$(( $nevt > 5000*9 ? ($nevt / 9) + ($nevt % 9 > 0) : 5000 ))
# set starting variables
produced_lhe=0
run_counter=0
# if rnum allows, multiply by 10 to avoid multiple runs 
# with the same seed across the workflow
run_random_start=$(($rnum*10))
# otherwise don't change the seed and increase number of events as 10000 if n_evt<50000 or n_evt/9 otherwise
if [  $run_random_start -gt "89999990" ]; then
    run_random_start=$rnum
    max_events_per_iteration=$(( $nevt > 10000*9 ? ($nevt / 9) + ($nevt % 9 > 0) : 10000 ))
fi

while [ $produced_lhe -lt $nevt ]; do
  
  # set the incremental iteration seed
  run_random_seed=$(($run_random_start + $run_counter))
  # increase the iteration counter
  let run_counter=run_counter+1 
  
  # don't allow more than 90 iterations
  if [  $run_counter -gt "90" ]; then
      echo "asking for more than 90 iterations, this should never happen"
      break
  fi
  # compute remaining events
  remaining_event=$(($nevt - $produced_lhe))
  
  echo "Running MG5_aMC for the "$run_counter" time"
  # set number of events to max_events_per_iteration or residual ones if less than that
  submitting_event=$(( $remaining_event < $max_events_per_iteration ? $remaining_event : $max_events_per_iteration ))
  # run mg5_amc
  echo "produced_lhe " $produced_lhe "nevt " $nevt "submitting_event " $submitting_event " remaining_event " $remaining_event
  echo run.sh $submitting_event $run_random_seed
  ../process/run.sh $submitting_event $run_random_seed
  
  # compute number of events produced in the iteration
  produced_lhe=$(($produced_lhe+`zgrep \<event events.lhe.gz | wc -l`))
  
  # rename output file to avoid overwriting
  mv events.lhe.gz events_${run_counter}.lhe.gz
  echo "run "$run_counter" finished, total number of produced events: "$produced_lhe"/"$nevt
  
  echo ""
  
done

# merge multiple lhe files if needed
ls -lrt events*.lhe.gz
if [  $run_counter -gt "1" ]; then
    echo "Merging files and deleting unmerged ones"
    cp /cvmfs/cms.cern.ch/phys_generator/gridpacks/lhe_merger/merge.pl ./
    chmod 755 merge.pl
    # ./madevent/bin/internal/merge.pl events*.lhe.gz events.lhe.gz banner.txt
    ./merge.pl events*.lhe.gz events.lhe.gz banner.txt
    rm events_*.lhe.gz banner.txt;
else
    mv events_${run_counter}.lhe.gz events.lhe.gz
fi

cd $LHEWORKDIR

} ### end of function


if [ $succ_setreadonly = false ] || [ $ncpu -eq 1 ] || [ $nevt -lt $ncpu ]; then
    echo "[MT] Use normal mode and run on single core"
    cd $LHEWORKDIR
    event_generate_per_thread 0 $nevt $rnum
    mv thread0/events.lhe.gz process/
    rm -r thread0
    cd process
else
    echo "[MT] Activate multi-threading for event generation -- will use $ncpu cores"
    nevt_ave=$(( $nevt / $ncpu ))
    for i in `seq 0 $(( $ncpu-2 ))`; do
        nevt_per_thread[$i]=$nevt_ave
    done
    nevt_per_thread[$(( $ncpu-1 ))]=$(( $nevt - ($ncpu-1)*$nevt_ave ))

    cd $LHEWORKDIR

    # make the gridpack directory read-only to enable the multi-threading feature
    if fs listacl &>/dev/null; then
        fs sa -dir process/madevent -acl ${USER} read
    else
        chmod -w process/madevent
    fi
    
    # when interrupt, resume write access and kill ALL multi-thread event generation commands
    trap "cd $LHEWORKDIR; if fs listacl &>/dev/null; then fs sa -dir process/madevent -acl ${USER} all; else chmod +w process/madevent; fi; kill 0" SIGINT SIGTERM EXIT
    for i in `seq 0 $(( $ncpu-1 ))`; do
        event_generate_per_thread $i ${nevt_per_thread[$i]} $((rnum+100*$i)) | sed -e "s/^/[Thread $i] /" &
    done; wait
    trap - SIGINT SIGTERM EXIT # resume

    if fs listacl &>/dev/null; then
        fs sa -dir process/madevent -acl ${USER} all
    else
        chmod +w process/madevent
    fi
    cd process

    # merge files produced in different threads
    cp /cvmfs/cms.cern.ch/phys_generator/gridpacks/lhe_merger/merge.pl ./
    chmod 755 merge.pl
    ./merge.pl ../thread*/events.lhe.gz events.lhe.gz banner.txt
    rm -r ../thread* banner.txt;
fi

#########################################
#########################################
#########################################

echo "run finished, produced number of events:"
zgrep \<event events.lhe.gz |wc -l

#reweight if necessary
doreweighting=0
if [ -e ./madevent/Cards/reweight_card.dat ]; then
    echo "reweighting events"
    doreweighting=1
    mkdir -p ./madevent/Events/GridRun_${rnum}/
    mv events.lhe.gz ./madevent/Events/GridRun_${rnum}/unweighted_events.lhe.gz
    cd madevent
    echo "0" |./bin/madevent --debug reweight GridRun_${rnum}
    cd ..
    mv $LHEWORKDIR/process/madevent/Events/GridRun_${rnum}/unweighted_events.lhe.gz $LHEWORKDIR/process/events.lhe.gz
fi

domadspin=0
if [ -f ./madspin_card.dat ] ;then
    domadspin=1
    echo "import events.lhe.gz" > madspinrun.dat
    rnum2=$(($rnum+1000000))
    echo `echo "set seed $rnum2"` >> madspinrun.dat
    cat ./madspin_card.dat >> madspinrun.dat
    $LHEWORKDIR/mgbasedir/MadSpin/madspin madspinrun.dat 
fi

cd $LHEWORKDIR

runlabel=GridRun_PostProc_${rnum}
mkdir process/madevent/Events/${runlabel}

event_file=events.lhe.gz
if [ "$domadspin" -gt "0" ] ; then 
    event_file=events_decayed.lhe.gz
fi
mv process/$event_file process/madevent/Events/${runlabel}/events.lhe.gz

# Add scale and PDF weights using systematics module
#
pushd process/madevent
pdfsets="PDF_SETS_REPLACE"
scalevars="--mur=1,2,0.5 --muf=1,2,0.5 --together=muf,mur,dyn --dyn=-1,1,2,3,4 --alps=0.5,1,2"

if [ "$doreweighting" -gt "0" ] ; then 
    echo "systematics $runlabel --start_id=1001 --pdf=$pdfsets $scalevars" | ./bin/madevent
else
    echo "systematics $runlabel --remove_wgts=all --start_id=1001 --pdf=$pdfsets $scalevars" | ./bin/madevent
fi

popd

mv process/madevent/Events/${runlabel}/events.lhe.gz cmsgrid_final.lhe.gz
gzip -d cmsgrid_final.lhe.gz

ls -l
echo

exit 0
