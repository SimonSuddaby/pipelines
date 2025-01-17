version 1.0

import "../../structs/gcp/RunTimeSettings.wdl"
import "../../structs/ReferenceSequence.wdl"

task SplitUpInputFile {
  input {
    File input_file
    String sample_id

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/lftp:1.0"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    RunTimeSettings runTimeSettings
  }

  String lanelet_file_prefix = "lanelet_"

  command {
    mkdir lanelet_temp
    cd lanelet_temp

    # Verify that the input_file begins with a header
    # should look like: `sample_id	run_ena	irods_path	bam_path	cram_path	read1_path	read2_path`
    head -1 ~{input_file} | grep '^sample_id\trun_ena'
    exitCode=$?
    if [ $exitCode != 0 ]; then
      echo "Input file ~{input_file} appears malformed"
      exit $exitCode
    fi

    # splits list of mappings into single files.  One line each.
    grep '^~{sample_id}\t' ~{input_file} | split -l 1 - ~{lanelet_file_prefix}
  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
  }

  output {
      Array[File] lanelet_files = glob("lanelet_temp/~{lanelet_file_prefix}*")
  }
}

task Ftp {
  input {
    String input_string
    String output_filename = basename(input_string)

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/lftp:1.0"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    RunTimeSettings runTimeSettings
  }

  command {

    set -e
    set -o pipefail

    echo get1 ~{input_string} -o ~{output_filename} > script_file
    lftp -f script_file

  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk 100 HDD"
  }

  output {
    File output_file = output_filename
  }
}

task CramToBam {
  input {
    File input_file
    String output_filename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/samtools:1.4.1"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 2
    ReferenceSequence reference
    RunTimeSettings runTimeSettings
  }

  Int disk_size = ceil(6 * size(input_file, "GiB"))

  command {

    set -e
    set -o pipefail

    samtools view -h -T ~{reference.ref_fasta} ~{input_file} |
    samtools view -b -o ~{output_filename} -
    samtools index -b ~{output_filename}

  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }

  output {
    File output_file = output_filename
    File output_file_index = "~{output_filename}.bai"
  }
}

# Sometimes the existing read group ID doesn't give useful info.
# Replace the read group ID with the bam/cram basename without the extension.
# Replaces the tabs with "\t" so that it can be used directly as a string
# parameter -R in bwa mem.
# Write out the new read group ID to file.
# Most useful where bam/cram has run, lane, tag information in its filename.
task ExtractReadGroup {
  input {
    File input_file
    String sample_id
    String read_group_filename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/samtools:1.4.1"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    RunTimeSettings runTimeSettings
  }

  Int disk_size = ceil(3 * size(input_file, "GiB")) + 20

  Boolean is_cram = sub(basename(input_file), ".*\\.", "") == "cram"
  String read_group_id = if is_cram then basename(input_file, ".cram")  else basename(input_file, ".bam")


  command {

    set -e
    set -o pipefail

    read_group=$( samtools view -H ~{input_file} | grep '^@RG')
    echo "$read_group" | sed -e "s/ID:\S*\s/ID:~{read_group_id}\t/" | \
      sed -e "s/SM:\S*\s/SM:~{sample_id}\t/" | \
      sed -e "s/\t/\\\\t/g" > ~{read_group_filename}

  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }

  output {
    File read_group_file = read_group_filename
  }
}

task RevertSam {
  input {
    File input_file
    String output_filename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/picard:2.9.2"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    RunTimeSettings runTimeSettings
  }

  Int disk_size = ceil(4 * size(input_file, "GiB")) + 20

  command {
    java -Xmx3500m -jar /bin/picard.jar \
      RevertSam \
      INPUT=~{input_file} \
      OUTPUT=~{output_filename} \
      VALIDATION_STRINGENCY=LENIENT \
      ATTRIBUTE_TO_CLEAR=FT \
      ATTRIBUTE_TO_CLEAR=CO \
      ATTRIBUTE_TO_CLEAR=PA \
      ATTRIBUTE_TO_CLEAR=OA \
      ATTRIBUTE_TO_CLEAR=XA
  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }

  output {
    File output_file = output_filename
  }
}

task SamToFastq {
  input {
    File input_file
    String output_fastq1_filename
    String output_fastq2_filename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/picard:2.9.2"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    RunTimeSettings runTimeSettings
  }

  Int disk_size = ceil(4 * size(input_file, "GiB")) + 20

  command {
    java -Xmx3500m -jar /bin/picard.jar \
      SamToFastq \
      INPUT=~{input_file} \
      FASTQ=~{output_fastq1_filename} \
      SECOND_END_FASTQ=~{output_fastq2_filename} \
      NON_PF=true
  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }

  output {
    File output_fastq1 = output_fastq1_filename
    File output_fastq2 = output_fastq2_filename
  }
}

# User must supply either one of read_group_id or read_group
# If they supply read_group_id, a fake read_group will  be generated as
# @RG  ID:~{read_group_id} SM:~{sample_id} CN:SC PL:ILLUMINA
task ReadAlignment {
  input {
    String? read_group_id
    String? read_group
    String sample_id
    File fastq1
    File fastq2
    String output_sam_basename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/bwa:0.7.15"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 4
    ReferenceSequence reference
    RunTimeSettings runTimeSettings
  }

  Float fastq_size = size(fastq1, "GiB") + size(fastq2, "GiB")
  Float ref_size = size(reference.ref_fasta, "GiB") + size(reference.ref_fasta_index, "GiB") + size(reference.ref_dict, "GiB")
  Float bwa_ref_size = ref_size + size(reference.ref_amb, "GiB") + size(reference.ref_ann, "GiB") + size(reference.ref_bwt, "GiB") + size(reference.ref_pac, "GiB") + size(reference.ref_sa, "GiB")
  Float disk_multiplier = 2.5
  Int disk_size = ceil(fastq_size + bwa_ref_size + (disk_multiplier * fastq_size) + 20)

  # suggested content for the read group tag: (from Thuy):
  # Read group identifier [ID]: full platform unit ID as the read group identifier (including the flowcell, run, lane)
  # library [LB]: obtained from raw sequenced bam, but we can make this up for testing
  # sample [SM]: obtained from raw sequenced bam, but we can also obtain this from the sample manifest or fastq filename
  # sequencing centre [CN]: obtained from raw sequenced bam, but we can make this up for testing
  # platform [PL]: obtained from raw sequenced bam, but we can make this up for testing
  # study [DS]: obtained from raw sequenced bam, but we can make this up for testing
  # @rg ID:130508_HS22_09812_A_D1U5TACXX_4#48 LB:7206533 SM:AN0131-C CN:SC PL:ILLUMINA DS:1087-AN-HAPMAP-DONNELLY
  String full_read_group_id = select_first([read_group_id, output_sam_basename])
  String autogen_read_group = "@RG\\tID:" + full_read_group_id + "\\tSM:" + sample_id + "\\tCN:SC\\tPL:ILLUMINA"
  String full_read_group = select_first([read_group, autogen_read_group])

  command {
    set -o pipefail
    set -e

    bwa mem -M -K 100000000 -t 4 -T 0 -R '~{full_read_group}' ~{reference.ref_fasta} ~{fastq1} ~{fastq2} > ~{output_sam_basename}.sam
  }
  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "15 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File output_sam = "~{output_sam_basename}.sam"
  }
}

task ReadAlignmentPostProcessing {
  input {
    File input_sam
    String output_bam_basename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/samtools:1.4.1"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 2
    RunTimeSettings runTimeSettings
  }

  Int disk_size = (ceil(size(input_sam, "GiB")) * 3) + 20

  command {

    set -e
    set -o pipefail

    samtools view -bu ~{input_sam} |
    samtools sort -n - |
    samtools fixmate - - |
    samtools sort - > ~{output_bam_basename}.bam

  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "14 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File output_bam = "~{output_bam_basename}.bam"
  }
}

task SetNmMdAndUqTags {
  input {
    File input_bam
    String output_bam_basename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/picard:2.9.2"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    ReferenceSequence reference
    RunTimeSettings runTimeSettings
  }

  Int disk_size = (ceil(size(input_bam, "GiB")) * 3) + 20

  command {
    java -Xmx3500m -jar /bin/picard.jar \
      SetNmMdAndUqTags \
      INPUT=~{input_bam} \
      OUTPUT=~{output_bam_basename}.bam \
      REFERENCE_SEQUENCE=~{reference.ref_fasta} \
      IS_BISULFITE_SEQUENCE=false
  }
  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File output_bam = "~{output_bam_basename}.bam"
  }
}

task MergeSamFiles {
  input {
    Array[File] input_files
    String output_filename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/picard:2.9.2"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    RunTimeSettings runTimeSettings
  }

  Int disk_size = (ceil(size(input_files, "GiB")) * 3) + 20

  command {
    java -Xmx3500m -jar /bin/picard.jar \
      MergeSamFiles \
      INPUT=~{sep=' INPUT=' input_files} \
      OUTPUT=~{output_filename}
  }
  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File output_file = output_filename
  }
}

task MarkDuplicates {
  input {
    File input_bam
    String output_filename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/biobambam2:2.0.73"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    RunTimeSettings runTimeSettings
  }

  Int disk_size = (ceil(size(input_bam, "GiB")) * 3) + 20

  command {
    /usr/local/bin/bammarkduplicates I=~{input_bam} O=~{output_filename} index=1
  }
  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    disks: "local-disk " + disk_size + " HDD"
    memory: "3.75 GiB"
  }
  output {
    File output_file = output_filename
    File output_index_file = "~{output_filename}.bai"
  }
}

task RealignerTargetCreator {
  input {
    File input_bam
    File input_bam_index
    File? known_indels_vcf
    String output_interval_list_filename

    String docker_tag = "broadinstitute/gatk3:3.7-0"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    ReferenceSequence reference
    RunTimeSettings runTimeSettings
  }

  Int disk_size = (ceil(size(input_bam, "GiB")) * 2) + 20

  command {
    java -XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -Xmx3500m \
          -jar /usr/GenomeAnalysisTK.jar \
          -T RealignerTargetCreator \
          -I ~{input_bam} \
          -R ~{reference.ref_fasta} \
          ~{"-known " + known_indels_vcf} \
          -o ~{output_interval_list_filename}
  }
  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File output_interval_list_file = output_interval_list_filename
  }
}

task IndelRealigner {
  input {
    File input_bam
    File input_bam_index
    File? known_indels_vcf
    File interval_list_file
    String output_bam_filename

    String docker_tag = "broadinstitute/gatk3:3.7-0"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    ReferenceSequence reference
    RunTimeSettings runTimeSettings
  }

  Int disk_size = (ceil(size(input_bam, "GiB")) * 2) + 20

  command {
    java -XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -Xmx7500m \
          -jar /usr/GenomeAnalysisTK.jar \
          -T IndelRealigner \
          -I ~{input_bam} \
          -R ~{reference.ref_fasta} \
          ~{"-known " + known_indels_vcf} \
          -targetIntervals ~{interval_list_file} \
          -o ~{output_bam_filename}
  }
  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "7.5 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File output_bam = output_bam_filename
  }
}

task FixMateInformation {
  input {
    File input_file
    String output_bam_basename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/picard:2.9.2"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    RunTimeSettings runTimeSettings
  }

  Int disk_size = (ceil(size(input_file, "GiB")) * 8) + 20

  command {
   set -e
   set -o pipefail

    java -Xmx7000m -jar /bin/picard.jar \
      FixMateInformation \
      INPUT=~{input_file} \
      OUTPUT=~{output_bam_basename}.bam \
      MAX_RECORDS_IN_RAM=300000 \
      CREATE_INDEX=true

      # FixMateInformation creates the bam index as foo.bai, we move it to foo.bam.bai
      mv ~{output_bam_basename}.bai ~{output_bam_basename}.bam.bai
  }
  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "7.5 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File output_bam = "~{output_bam_basename}.bam"
    File output_bam_index = "~{output_bam_basename}.bam.bai"
  }
}

task ValidateSamFile {
  input {
    File input_file
    File? input_file_index
    String report_filename
    Int? max_output
    Array[String]? ignore

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/picard:2.9.2"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    ReferenceSequence reference
    RunTimeSettings runTimeSettings
  }

  Float ref_size = size(reference.ref_fasta, "GiB") + size(reference.ref_fasta_index, "GiB") + size(reference.ref_dict, "GiB")
  Int disk_size = ceil(size(input_file, "GiB") + ref_size) + 20

  command {
    java -Xmx3500m -jar /bin/picard.jar \
      ValidateSamFile \
      INPUT=~{input_file} \
      OUTPUT=~{report_filename} \
      REFERENCE_SEQUENCE=~{reference.ref_fasta} \
      ~{"MAX_OUTPUT=" + max_output} \
      IGNORE=~{default="null" sep=" IGNORE=" ignore} \
      IS_BISULFITE_SEQUENCED=false \
      MODE=VERBOSE
  }
  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File report_file = report_filename
  }
}

task SamtoolsStats {
  input {
    File input_file
    String report_filename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/samtools:1.4.1"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    ReferenceSequence reference
    RunTimeSettings runTimeSettings
  }

  Float ref_size = size(reference.ref_fasta, "GiB") + size(reference.ref_fasta_index, "GiB") + size(reference.ref_dict, "GiB")
  Int disk_size = ceil(size(input_file, "GiB") + ref_size) + 20

  command {

    set -e
    set -o pipefail

    samtools stats -r ~{reference.ref_fasta} ~{input_file} > ~{report_filename}

  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "7.5 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File report_file = report_filename
  }
}

task SamtoolsIdxStats {
  input {
    File input_bam
    File input_bam_index
    String report_filename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/samtools:1.4.1"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    RunTimeSettings runTimeSettings
  }

  Int disk_size = ceil(size(input_bam, "GiB")) + 20

  command {

    set -e
    set -o pipefail

    samtools idxstats ~{input_bam} > ~{report_filename}

  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File report_file = report_filename
  }
}

task SamtoolsFlagStat {
  input {
    File input_bam
    String report_filename

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/samtools:1.4.1"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    RunTimeSettings runTimeSettings
  }

  Int disk_size = ceil(size(input_bam, "GiB")) + 20

  command {

    set -e
    set -o pipefail

    samtools flagstat ~{input_bam} > ~{report_filename}

  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File report_file = report_filename
  }
}

task GatkCallableLoci {
  input {
    File input_bam
    File input_bam_index
    String summary_filename

    String docker_tag = "broadinstitute/gatk3:3.7-0"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 1
    ReferenceSequence reference
    RunTimeSettings runTimeSettings
  }

  Int disk_size = (ceil(size(input_bam, "GiB")) * 2) + 20

  command {
    java -XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -Xmx3500m \
          -jar /usr/GenomeAnalysisTK.jar \
          -T CallableLoci \
          -I ~{input_bam} \
          -R ~{reference.ref_fasta} \
          --summary ~{summary_filename} \
          --minDepth 5
  }
  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
  }
  output {
    File summary_file = summary_filename
  }
}

task SamtoolsIndex {
  input {
    File input_file

    String docker_tag = "us.gcr.io/broad-gotc-prod/malariagen/samtools:1.4.1"
    Int preemptible_tries = runTimeSettings.preemptible_tries
    Int num_cpu = 2
    RunTimeSettings runTimeSettings
    String runtime_zones = "us-central1-b"
  }

  Int disk_size = ceil(3 * size(input_file, "GiB")) + 20

  String local_file = basename(input_file)

  command {

    set -e
    set -o pipefail

    # Localize the passed input_file to the working directory so when the
    # newly created index file doesn't get delocalized with the long path.
    cp ~{input_file} ~{local_file}
    samtools index -b ~{local_file}

  }

  runtime {
    docker: docker_tag
    preemptible: preemptible_tries
    cpu: num_cpu
    memory: "3.75 GiB"
    disks: "local-disk " + disk_size + " HDD"
    zones: runtime_zones
  }

  output {
    # output the path to the copied local file AND the created index so they are side by side.
    File output_file = local_file
    File output_index_file = "~{local_file}.bai"
  }
}