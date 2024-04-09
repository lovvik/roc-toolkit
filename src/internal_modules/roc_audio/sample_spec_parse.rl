/*
 * Copyright (c) 2023 Roc Streaming authors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#include "roc_audio/channel_tables.h"
#include "roc_audio/sample_spec.h"
#include "roc_core/log.h"
#include "roc_core/macro_helpers.h"
#include "roc_core/panic.h"

namespace roc {
namespace audio {

%%{
    machine parse_sample_spec;
    write data;
}%%

namespace {

bool parse_size_t(const char* str, size_t str_len, size_t& result) {
    char* str_end = NULL;
    long num = strtol(str, &str_end, 10);

    if (num == LONG_MAX || num == LONG_MIN || str_end != str + str_len) {
        return false;
    }
    if (num < 0 || (uint64_t)num > (uint64_t)ROC_MAX_OF(size_t)) {
        return false;
    }

    result = (size_t)num;
    return true;
}

bool parse_surround_channel(const char* str, size_t str_len, ChannelPosition& result) {
    for (size_t i = 0; i < ROC_ARRAY_SIZE(ChanPositionNames); i++) {
        if (strlen(ChanPositionNames[i].name) == str_len &&
            memcmp(ChanPositionNames[i].name, str, str_len) == 0) {
            result = ChanPositionNames[i].pos;
            return true;
        }
    }

    return false;
}

bool parse_surround_mask(const char* str, size_t str_len, ChannelMask& result) {
    for (size_t i = 0; i < ROC_ARRAY_SIZE(ChanMaskNames); i++) {
        if (strlen(ChanMaskNames[i].name) == str_len &&
            memcmp(ChanMaskNames[i].name, str, str_len) == 0) {
            result = ChanMaskNames[i].mask;
            return true;
        }
    }

    return false;
}

bool parse_multitrack_channel(const char* str, size_t str_len, size_t& result) {
    if (!parse_size_t(str, str_len, result)) {
        return false;
    }

    if (result >= ChannelSet::max_channels()) {
        return false;
    }

    return true;
}

bool parse_multitrack_mask(const char* str, size_t str_len, ChannelSet& result) {
    size_t str_pos = str_len - 1;
    size_t ch_pos = 0;

    do {
        char digit_str[2] = { str[str_pos], '\0' };
        char* digit_end = NULL;

        const long num = (unsigned)strtol(digit_str, &digit_end, 16);
        if (num == LONG_MAX || num == LONG_MIN || digit_end != digit_str + 1) {
            return false;
        }

        for (size_t bit = 0; bit < 4; bit++) {
            if (num & (1 << bit)) {
                result.toggle_channel(ch_pos, true);
            }
            ch_pos++;
        }
    } while (str_pos-- != 0);

    return true;
}

bool parse_sample_rate(const char* str, size_t str_len, size_t& result) {
    if (!parse_size_t(str, str_len, result)) {
        return false;
    }

    if (result == 0) {
        return false;
    }

    return true;
}

bool parse_sample_spec_imp(const char* str, SampleSpec& sample_spec) {
    if (!str) {
        roc_log(LogError, "parse sample spec: input string is null");
        return false;
    }

    sample_spec.clear();

    // for ragel
    const char* p = str;
    const char *pe = str + strlen(str);

    const char *eof = pe;
    int cs = 0;

    // for start_token
    const char* start_p = NULL;

    // for mtr range
    size_t mtr_range_begin = 0,
        mtr_range_end = 0;

    // parse result
    bool success = false;

    %%{
        action start_token {
            start_p = p;
        }

        action set_surround_mask {
            ChannelMask ch_mask = 0;
            if (!parse_surround_mask(start_p, p - start_p, ch_mask)) {
                roc_log(LogError, "parse sample spec: invalid channel mask name");
                return false;
            }
            sample_spec.channel_set().set_mask(ch_mask);
        }

        action set_surround_channel {
            ChannelPosition ch_pos = ChanPos_Max;
            if (!parse_surround_channel(start_p, p - start_p, ch_pos)) {
                roc_log(LogError, "parse sample spec: invalid channel name");
                return false;
            }
            sample_spec.channel_set().toggle_channel(ch_pos, true);
        }

        action set_surround {
            sample_spec.channel_set().set_layout(ChanLayout_Surround);
            sample_spec.channel_set().set_order(ChanOrder_Smpte);
        }

        action set_mtr_number {
            size_t ch_pos = 0;
            if (!parse_multitrack_channel(start_p, p - start_p, ch_pos)) {
                roc_log(LogError, "parse sample spec: invalid channel number,"
                    " should be integer in range [0; %d]",
                    (int)ChannelSet::max_channels() - 1);
                return false;
            }
            sample_spec.channel_set().toggle_channel(ch_pos, true);
        }

        action set_mtr_range_begin {
            if (!parse_multitrack_channel(start_p, p - start_p, mtr_range_begin)) {
                roc_log(LogError, "parse sample spec: invalid channel number,"
                    " should be integer in range [0; %d]",
                    (int)ChannelSet::max_channels() - 1);
                return false;
            }
        }

        action set_mtr_range_end {
            if (!parse_multitrack_channel(start_p, p - start_p, mtr_range_end)) {
                roc_log(LogError, "parse sample spec: invalid channel number,"
                    " should be integer in range [0; %d]",
                    (int)ChannelSet::max_channels() - 1);
                return false;
            }
        }

        action set_mtr_range {
            sample_spec.channel_set().toggle_channel_range(
                mtr_range_begin, mtr_range_end, true);
        }

        action set_mtr_mask {
            if (!parse_multitrack_mask(start_p, p - start_p, sample_spec.channel_set())) {
                roc_log(LogError, "parse sample spec: invalid channel mask");
                return false;
            }
        }

        action set_mtr {
            sample_spec.channel_set().set_layout(ChanLayout_Multitrack);
            sample_spec.channel_set().set_order(ChanOrder_None);
        }

        action set_format {
            char str[16] = {};
            strncat(str, start_p, p - start_p);
            PcmFormat pcm_fmt = pcm_format_from_str(str);
            if (pcm_fmt == PcmFormat_Invalid) {
                roc_log(LogError, "parse sample spec: invalid sample format");
                return false;
            }
            sample_spec.set_sample_format(SampleFormat_Pcm);
            sample_spec.set_pcm_format(pcm_fmt);
        }

        action set_rate {
            size_t rate = 0;
            if (!parse_sample_rate(start_p, p - start_p, rate)) {
                roc_log(LogError, "parse sample spec: invalid sample rate");
                return false;
            }
            sample_spec.set_sample_rate(rate);
        }

        surround_mask = ([a-z] [a-z0-9.]+) >start_token %set_surround_mask;
        surround_channel = [A-Z]+ >start_token %set_surround_channel;
        surround_list = surround_channel (',' surround_channel)*;

        surround = (surround_mask | surround_list) %set_surround;

        mtr_mask_hex = [0-9a-fA-F]+ >start_token %set_mtr_mask;
        mtr_mask = '0x' mtr_mask_hex;

        mtr_number = [0-9]+ >start_token %set_mtr_number;
        mtr_range_begin = [0-9]+ >start_token %set_mtr_range_begin;
        mtr_range_end = [0-9]+ >start_token %set_mtr_range_end;
        mtr_range = (mtr_range_begin '-' mtr_range_end) >start_token %set_mtr_range;
        mtr_channel = mtr_number | mtr_range;
        mtr_list = mtr_channel (',' mtr_channel)*;

        mtr = (mtr_mask | mtr_list) %set_mtr;

        format = [a-z0-9_]+ >start_token %set_format;
        rate = [0-9]+ >start_token %set_rate;
        channels = surround | mtr;

        main := ( ('-' | format) '/' ('-' | rate) '/' ('-' | channels) )
                %{ success = true; }
                ;

        write init;
        write exec;
    }%%

    if (!success) {
        roc_log(LogError,
                "parse sample spec: expected 'FORMAT/RATE/CHANNELS', got '%s'",
                str);
        return false;
    }

    return true;
}

} // namespace

bool parse_sample_spec(const char* str, SampleSpec& result) {
    if (!parse_sample_spec_imp(str, result)) {
        result.clear();
        return false;
    }
    return true;
}

} // namespace audio
} // namespace roc
