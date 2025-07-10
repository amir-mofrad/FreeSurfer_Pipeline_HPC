#!/bin/bash

# ============================
# FreeSurfer Longitudinal Pipeline Batching Launcher
# Author: Amir Mofrad, Abhirup Mukherjee, and Khalid Sarwar Warraich
# Date: June 2025
# ============================

set -euo pipefail

## ----------- CONFIGURATION -------------
FREESURFER_INIT="/opt/ohpc/pub/apps/freesurfer/8.0.0/initialize_env.sh"
CORES_PER_NODE=64
TIME_LIMIT="48:00:00"
LAUNCHER_MODULE="launcher/3.9"

## ----------- GET INPUT NIFTI FILES + GROUPING -------------
pwd_dir=$(pwd)
mapfile -t nii_files < <(find "$pwd_dir" -maxdepth 1 -type f -name "*.nii*" -print)

if [ "${#nii_files[@]}" -eq 0 ]; then
  echo "[ERROR] No .nii or .nii.gz files found in: $pwd_dir"
  exit 1
fi

declare -A subj_map

for fpath in "${nii_files[@]}"; do
  fname=$(basename "$fpath")
  id_prefix=$(echo "$fname" | grep -o 'NDAR_INV[A-Z0-9]\+' | sed 's/NDAR_INV/NDARINV/')
  subj_map["$id_prefix"]+="$fpath "
done

subjects=(${!subj_map[@]})
total_subjects=${#subjects[@]}
echo "Found $total_subjects unique subjects."

batch_size=3
echo "[INFO] Limiting to $batch_size subjects per batch due to memory constraints."

batch_count=$(( (total_subjects + batch_size - 1) / batch_size ))
mkdir -p batches
batch_dir_prefix="batch_"

for ((batch_idx=0; batch_idx<batch_count; batch_idx++)); do
  start=$(( batch_idx * batch_size ))
  end=$(( start + batch_size - 1 ))
  batch_name=$(printf "%s%03d" "$batch_dir_prefix" $((batch_idx + 1)))
  batch_dir="batches/$batch_name"
  mkdir -p "$batch_dir/logs"

  echo "Preparing $batch_name with subjects index $start to $end"

  raw_tasks="$batch_dir/raw_tasks.txt"
  base_tasks="$batch_dir/base_tasks.txt"
  long_tasks="$batch_dir/long_tasks.txt"
  seg_tasks="$batch_dir/segment_tasks.txt"

  > "$raw_tasks"
  > "$base_tasks"
  > "$long_tasks"
  > "$seg_tasks"

  declare -A base_map

  for ((i=start; i<=end && i<total_subjects; i++)); do
    subject="${subjects[$i]}"
    timepoints=( ${subj_map[$subject]} )

    for tp_file in "${timepoints[@]}"; do
      mv "$tp_file" "$batch_dir/"
    done

    for j in "${!timepoints[@]}"; do
      tp_path="${timepoints[$j]}"
      tp_file_name=$(basename "$tp_path")
      fname_noext="${tp_file_name%.*}"
      id_part="$subject"
      paren_part=$(echo "$fname_noext" | grep -oP '\(.*?\)' | tr -d '()' | tr -d ' _,')
      subjid="${id_part}_${paren_part}"

      echo "source $FREESURFER_INIT && export SUBJECTS_DIR=\$PWD && recon-all -subjid $subjid -i \"$tp_file_name\" -all" >> "$raw_tasks"
      base_map["$subject"]+="$subjid "
    done
  done

  for subject in "${!base_map[@]}"; do
    base_cmd="source $FREESURFER_INIT && export SUBJECTS_DIR=\$PWD && recon-all -base ${subject}_long"
    for tp in ${base_map[$subject]}; do
      base_cmd+=" -tp $tp"
    done
    base_cmd+=" -all"
    echo "$base_cmd" >> "$base_tasks"
  done

  for subject in "${!base_map[@]}"; do
    tps=( ${base_map[$subject]} )
    for tp in "${tps[@]}"; do
      echo "source $FREESURFER_INIT && export SUBJECTS_DIR=\$PWD && recon-all -long $tp ${subject}_long -all" >> "$long_tasks"
    done
  done

  for subject in "${!base_map[@]}"; do
    echo "source $FREESURFER_INIT && export SUBJECTS_DIR=\$PWD && segmentHA_T1_long.sh ${subject}_long \$SUBJECTS_DIR" >> "$seg_tasks"
  done

  write_launcher_slurm() {
    local jobname=$1
    local taskfile=$2
    local outfile=$3
    local batch_tag=$4
    local task_count
    task_count=$(wc -l < "$taskfile")
    local required_nodes=$(( (task_count + CORES_PER_NODE - 1) / CORES_PER_NODE ))

    cat <<EOF_SLURM > "$outfile"
#!/bin/bash
#SBATCH -p normal
#SBATCH --job-name=${jobname}-${batch_tag}
#SBATCH --ntasks=$task_count
#SBATCH --cpus-per-task=4
#SBATCH --nodes=$required_nodes
#SBATCH --time=$TIME_LIMIT
#SBATCH --output=logs/${jobname}-${batch_tag}_%j.out
#SBATCH --error=logs/${jobname}-${batch_tag}_%j.err
#SBATCH --mail-type=ALL
#SBATCH --mail-user=dal247378@utdallas.edu

cd \$SLURM_SUBMIT_DIR

module load $LAUNCHER_MODULE

export LAUNCHER_JOB_FILE=$(basename "$taskfile")
export LAUNCHER_WORKDIR=\$PWD
export LAUNCHER_SCHED=interleaved

\$LAUNCHER_DIR/paramrun
EOF_SLURM
  }

  write_launcher_slurm "recon_raw" "$raw_tasks" "$batch_dir/launcher_raw.slurm" "$batch_name"
  write_launcher_slurm "recon_base" "$base_tasks" "$batch_dir/launcher_base.slurm" "$batch_name"
  write_launcher_slurm "recon_long" "$long_tasks" "$batch_dir/launcher_long.slurm" "$batch_name"
  write_launcher_slurm "recon_segment" "$seg_tasks" "$batch_dir/launcher_segment.slurm" "$batch_name"

  cat <<EOF_SUBMIT > "$batch_dir/submit_pipeline.sh"
#!/bin/bash
set -euo pipefail

echo "Submitting STEP 1: Raw Reconstructions..."
jid_raw=\$(sbatch --parsable launcher_raw.slurm)
echo "  → Raw job submitted: \$jid_raw"
sleep 1
echo "Submitting STEP 2: Base Creation..."
jid_base=\$(sbatch --parsable --dependency=afterok:\$jid_raw launcher_base.slurm)
echo "  → Base job submitted: \$jid_base"
sleep 1
echo "Submitting STEP 3: Longitudinal Recon..."
jid_long=\$(sbatch --parsable --dependency=afterok:\$jid_base launcher_long.slurm)
echo "  → Longitudinal job submitted: \$jid_long"
sleep 1
echo "Submitting STEP 4: Segmentation..."
jid_seg=\$(sbatch --parsable --dependency=afterok:\$jid_long launcher_segment.slurm)
echo "  → Segmentation job submitted: \$jid_seg"

echo ""
echo "All jobs submitted with dependencies."
echo "  Final Segmentation Job ID: \$jid_seg"
EOF_SUBMIT

  chmod +x "$batch_dir/submit_pipeline.sh"
done

cat <<'EOF_RUN_ALL' > run_all_batches.sh
#!/bin/bash
set -euo pipefail

echo "Starting sequential execution of all batch pipelines..."

for batch_dir in $(find batches -maxdepth 1 -type d -name 'batch_*' | sort); do
  echo ""
  echo "Entering $batch_dir"
  cd "$batch_dir"

  if [[ ! -x "./submit_pipeline.sh" ]]; then
    echo "[WARNING] No submit_pipeline.sh found in $batch_dir, skipping..."
    cd - > /dev/null
    continue
  fi

  echo "Submitting pipeline for $batch_dir..."
  final_jid=$(./submit_pipeline.sh | grep 'Final Segmentation Job ID:' | awk '{print $NF}')

  echo "Waiting for Job ID $final_jid to finish..."
  while squeue -j "$final_jid" 2>/dev/null | grep -q "$final_jid"; do
    sleep 30
  done

  echo "Batch $batch_dir completed."
  cd - > /dev/null
done

echo ""
echo "All batches completed."
EOF_RUN_ALL

chmod +x run_all_batches.sh

echo ""
echo "Created run_all_batches.sh"
echo "To launch all batches sequentially, run:"
echo "  ./run_all_batches.sh"
