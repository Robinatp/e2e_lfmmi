#!/usr/bin/env bash

# author: tyriontian
# tyriontian@tencent.com

. ./path.sh || exit 1;
. ./cmd.sh || exit 1;

# general configuration
backend=pytorch
stage=0        # start from 0 if you need to start from data preparation
stop_stage=100
debugmode=1
dumpdir=dump   # directory to dump full features
N=0            # number of minibatches to be used (mainly for debugging). "0" uses all minibatches.
verbose=0      # verbose option
resume=        # Resume the training from snapshot
debug=false

# feature configuration
do_delta=false

preprocess_config=conf/specaug.yaml
train_config=conf/tuning/transducer/train_conformer-rnn_transducer_aux_ngpu4.yaml
lm_config=conf/lm.yaml
decode_config=conf/tuning/transducer/decode_default.yaml

# rnnlm related
lm_resume=         # specify a snapshot file to resume LM training
lmtag=             # tag for managing LMs

# ngram
ngramtag=
n_gram=4

# decoding parameter
recog_model=model.acc.best # set a model to be used for decoding: 'model.acc.best' or 'model.loss.best'

# data
data=/data/asr_data/aishell/
data_url=www.openslr.org/resources/33
dict=data/lang_1char/train_sp_units.txt
lang=data/lang_phone

### Configurable parameters ###
tag="8v100_ddp_rnnt_mmi"
ngpu=8

# Train config
seed=888
batch_size=8
accum_grad=1
epochs=100
use_segment=true # if true, use word-level transcription in MMI criterion
aux_ctc=true
aux_ctc_weight=0.5
aux_ctc_dropout_rate=0.1
aux_mmi=true
aux_mmi_weight=0.5
aux_mmi_dropout_rate=0.1
aux_mmi_type='mmi' # mmi or phonectc
att_scorer_weight=0.0

# MBR training config
aux_mbr=false
aux_mbr_weight=1.0
aux_mbr_beam=4
mbr_epochs=100
mbr_lr=0.1
mbr_warmup=8000
mbr_resume=exp/train_sp_pytorch_8v100_ddp_rnnt_noaux/results_0/snapshot.ep.100
# For second-stage training only. If false, only load the model weights but ignore chainer.trainer and optimizer state
load_trainer_and_opt=false

# Decode config
idx_average=91_100
search_type="alsd" # "default", "nsc", "tsd", "alsd"
mmi_weight=0.0 # MMI / phonectc joint decoding
ctc_weight=0.0 # char ctc joint decoding
ngram_order=4
ngram_weight=0.0
lm_weight=0.0
word_ngram_weight=0.0
word_ngram_order=3
word_ngram_log_semiring=true
mmi_type="frame" # or rescore
beam_size=10
recog_set="test dev"

. utils/parse_options.sh || exit 1;

if [ $debug == true ]; then
    export HOST_GPU_NUM=1
    export HOST_NUM=1
    export NODE_NUM=1
    export INDEX=0
    export CHIEF_IP="9.135.217.29"
fi

train_opts=\
"\
--seed $seed \
--batch-size $batch_size \
--accum-grad $accum_grad \
--epochs $epochs \
--use-segment $use_segment \
--aux-ctc $aux_ctc \
--aux-ctc-weight $aux_ctc_weight \
--aux-ctc-dropout-rate $aux_ctc_dropout_rate \
--aux-mmi $aux_mmi \
--aux-mmi-weight $aux_mmi_weight \
--aux-mmi-dropout-rate $aux_mmi_dropout_rate \
--aux-mmi-type $aux_mmi_type \
--att-scorer-weight $att_scorer_weight \
"

if [ $aux_mbr == true ]; then
    train_opts="$train_opts \
                --aux-mbr $aux_mbr \
                --aux-mbr-weight $aux_mbr_weight \
                --aux-mbr-beam $aux_mbr_beam \
                --transformer-lr $mbr_lr \
                --epochs $mbr_epochs \
                --transformer-warmup-steps $mbr_warmup \
                --resume $mbr_resume \
                --load-trainer-and-opt $load_trainer_and_opt \
                "
    export OMP_NUM_THREADS=6 # for on-the-fly decoding
fi

decode_opts=\
"\
--search-type $search_type \
--mmi-weight $mmi_weight \
--beam-size $beam_size \
--ctc-weight $ctc_weight \
--mmi-type $mmi_type \
--ngram-weight $ngram_weight \
--word-ngram-weight $word_ngram_weight \
--word-ngram data/word_${word_ngram_order}gram \
--word-ngram-log-semiring ${word_ngram_log_semiring} \
--lm-weight $lm_weight \
"

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

train_set=train_sp
train_dev=dev

expname=${train_set}_${backend}_${tag}
expdir=exp/${expname}
mkdir -p ${expdir}

feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}; mkdir -p ${feat_dt_dir}
if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    echo "stage 1: Network Training"

    # make sure in jizhi config file: "exec_start_in_all_mpi_pods": true, 
    MASTER_PORT=22277
    NCCL_DEBUG=TRACE python3 -m torch.distributed.launch \
        --nproc_per_node ${HOST_GPU_NUM} --master_port $MASTER_PORT \
        --nnodes=${HOST_NUM} --node_rank=${INDEX} --master_addr=${CHIEF_IP} \
        ${MAIN_ROOT}/bin/asr_train.py \
        --config ${train_config} \
        --preprocess-conf ${preprocess_config} \
        --ngpu 1 \
        --backend ${backend} \
        --outdir ${expdir}/results_RANK \
        --debugmode ${debugmode} \
        --dict ${dict} \
        --debugdir ${expdir} \
        --minibatches ${N} \
        --verbose ${verbose} \
        --resume ${resume} \
        --train-json ${feat_tr_dir}/split${ngpu}utt/data.RANK.json \
        --valid-json ${feat_dt_dir}/data.json \
        --lang $lang \
        --opt "noam_sgd" \
        --n-iter-processes 8 \
        --world-size $ngpu \
        --node-rank ${INDEX} \
        --node-size ${HOST_GPU_NUM} \
        $train_opts > ${expdir}/global_record.${INDEX}.txt 2>&1
fi

if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    echo "stage 2: Decoding"
    nj=188
    if [[ $(get_yaml.py ${train_config} model-module) = *transformer* ]] || \
           [[ $(get_yaml.py ${train_config} model-module) = *conformer* ]] || \
           [[ $(get_yaml.py ${train_config} etype) = custom ]] || \
           [[ $(get_yaml.py ${train_config} dtype) = custom ]]; then
        recog_model=model.last${idx_average}.avg.best
        average_checkpoints.py --backend ${backend} \
         		       --snapshots ${expdir}/results_0/snapshot.ep.* \
         		       --out ${expdir}/results_0/${recog_model} \
        		       --num ${idx_average}
    fi

    for rtask in ${recog_set}; do
    
        decode_dir=decode_${rtask}_ctc${ctc_weight}_mmi${mmi_weight}_${ngram_order}ngram${ngram_weight}_${word_ngram_order}wngram${word_ngram_weight}_log${word_ngram_log_semiring}_lm${lm_weight}
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}

        # split data
        splitjson.py --parts ${nj} ${feat_recog_dir}/data.json

        #### use CPU for decoding
        ngpu=0

        # If use rnnlm, download the official ckpts and add:
        # --rnnlm exp/train_rnnlm_pytorch_lm/official_ckpts/rnnlm.model.best \
        # --rnnlm-conf exp/train_rnnlm_pytorch_lm/official_ckpts/model.json \

        # If use character-level N-gram lm, train with kenlm and add:
        # --ngram-model exp/train_ngram/${ngram_order}gram.bin \

        ${decode_cmd} JOB=1:${nj} ${expdir}/${decode_dir}/log/decode.JOB.log \
            asr_recog.py \
            --config ${decode_config} \
            --ngpu ${ngpu} \
            --backend ${backend} \
            --batchsize 0 \
            --recog-json ${feat_recog_dir}/split${nj}utt/data.JOB.json \
            --result-label ${expdir}/${decode_dir}/data.JOB.json \
            --model ${expdir}/results_0/${recog_model} \
            --local-rank JOB \
            $decode_opts

        score_sclite.sh ${expdir}/${decode_dir} ${dict} \
          > ${expdir}/${decode_dir}/decode_result.txt
     
    done
    echo "Finished"
fi
