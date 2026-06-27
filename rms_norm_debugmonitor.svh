
//===========================================================================
// DEBUG State Transitions and Cycle Counters
//===========================================================================
generate
  if (DEBUG_CYCLES)
  begin
    // ----------------------------------------------------------------------
    // 1. INPUT FSM COUNTERS
    // ----------------------------------------------------------------------
    int cnt_in_accum, cnt_in_drain, cnt_in_reduce_init, cnt_in_reduce;
    int input_total_reg; // Stores the result of the LAST completed input phase
    // NOTE2me In back-to-back (pipelined) mode, this may be overwritten by the next job
    // before the output FSM prints it. Valid only for single-job tests.

    always_ff @(posedge clk or negedge rst_n)
    begin
      if (!rst_n)
      begin
        cnt_in_accum <= 0;
        cnt_in_drain <= 0;
        cnt_in_reduce_init <= 0;
        cnt_in_reduce <= 0;
        input_total_reg <= 0;
      end
      else
      begin
        // RESET: Exactly when the Input FSM starts a new job (entering ACCUM)
        if (state_in_next == S_IN_ACCUM && state_in != S_IN_ACCUM)
        begin
          cnt_in_accum <= 0;
          cnt_in_drain <= 0;
          cnt_in_reduce_init <= 0;
          cnt_in_reduce <= 0;
        end
        // COUNT: Increment based on current state
        else
        begin
          if (state_in == S_IN_ACCUM)
            cnt_in_accum <= cnt_in_accum + 1;
          if (state_in == S_IN_DRAIN)
            cnt_in_drain <= cnt_in_drain + 1;
          if (state_in == S_IN_REDUCE_INIT)
            cnt_in_reduce_init <= cnt_in_reduce_init + 1;
          if (state_in == S_IN_REDUCE)
            cnt_in_reduce <= cnt_in_reduce + 1;
        end

        // SNAPSHOT when input finishes by leaving REDUCE, save the total.
        // This prevents the data from being lost when the counters reset for the next vector.
        if (state_in == S_IN_REDUCE && state_in_next != S_IN_REDUCE)
        begin
          input_total_reg <= cnt_in_accum + cnt_in_drain + cnt_in_reduce_init + cnt_in_reduce;
        end
      end
    end

    // ----------------------------------------------------------------------
    // 2. OUTPUT FSM COUNTERS & PRINTING
    // ----------------------------------------------------------------------
    int cnt_out_mean, cnt_out_inv, cnt_out_stream;
    int cnt_wall_clock;

    always_ff @(posedge clk or negedge rst_n)
    begin
      if (!rst_n)
      begin
        cnt_out_mean <= 0;
        cnt_out_inv <= 0;
        cnt_out_stream <= 0;
        cnt_wall_clock <= 0;
      end
      else
      begin
        // RESET when starting a new output
        if ((state_out == S_OUT_IDLE && state_out_next != S_OUT_IDLE) ||
            (state_out == S_OUT_DONE && state_out_next != S_OUT_DONE))
        begin
          cnt_out_mean <= 0;
          cnt_out_inv <= 0;
          cnt_out_stream <= 0;
          cnt_wall_clock <= 0;
        end
        // COUNT
        else
        begin
          if (state_out == S_OUT_CALC_MEAN)
            cnt_out_mean <= cnt_out_mean + 1;
          if (state_out == S_OUT_CALC_INV)
            cnt_out_inv <= cnt_out_inv + 1;
          if (state_out == S_OUT_STREAM)
            cnt_out_stream <= cnt_out_stream + 1;

          // Count wall clock if ANY part of the core is busy
          if (busy)
            cnt_wall_clock <= cnt_wall_clock + 1;
        end

        // PRINT when output finishes
        if (state_out == S_OUT_STREAM && state_out_next == S_OUT_DONE)
        begin
          $display("  === CYCLE BREAKDOWN (dim=%0d) ===", MAX_VECTOR_SIZE);
          // Print the LATCHED input stats (from the past)
          $display("  [Input Phase]  Total: %0d cycles ", input_total_reg);
          // Print the CURRENT output stats
          $display("  [Output Phase] MEAN: %0d, INV: %0d, STREAM: %0d",
                   cnt_out_mean, cnt_out_inv, cnt_out_stream);
          $display("  --------------------------------");
          // In a ping-pong test, this number represents the "Pipeline Stage Latency" (max of input/output)
          $display("  Computation Phase Latency (Mean + Inverse + Stream): %0d cycles", cnt_wall_clock);
          $display("  ====================================");
        end
      end
    end
  end
endgenerate

generate
  if (DEBUG)
  begin : gen_debug
    always_ff @(posedge clk)
    begin
      if (DEBUG && state_out == S_OUT_STREAM && !credit_available && $time % 1000 == 0)
        $display("[RMS_NORM] Backpressure active: m_axis_tready=%b credit=%b", m_axis_tready, credit_available);
    end 
    // Credit system debug displays
    always_ff @(posedge clk)
    begin
      if (state_out == S_OUT_STREAM)
      begin
        // Periodic status every 100 cycles
        if ($time % 1000 == 0)
        begin
          $display("[%0t] CREDIT: cnt=%0d, avail=%b, consume=%b, return=%b, beat_cnt=%0d, fifo_re=%b, stream_fed=%0d",
                   $time, credit_counter, credit_available, credit_consume, credit_return,
                   credit_beat_cnt, fifo_re, stream_fed_count);
        end

        // Alert when credits run low
        if (credit_counter <= 2 && !credit_available)
        begin
          $display("[%0t] CREDIT WARNING: Credits exhausted! cnt=%0d, m_axis_tvalid=%b, m_axis_tready=%b",
                   $time, credit_counter, m_axis_tvalid, m_axis_tready);
        end

        // Alert on credit underflow attempt (should never happen)
        if (credit_consume && credit_counter == 0)
        begin
          $display("[%0t] CREDIT ERROR: Attempting to consume with 0 credits!", $time);
        end
      end
    end

    function automatic string state_in_name(state_in_t s);
      case (s)
        S_IN_IDLE:
          return "IN_IDLE";
        S_IN_ACCUM:
          return "IN_ACCUM";
        S_IN_DRAIN:
          return "IN_DRAIN";
        S_IN_REDUCE_INIT:
          return "IN_REDUCE_INIT";
        S_IN_REDUCE:
          return "IN_REDUCE";
        default:
          return "UNKNOWN";
      endcase
    endfunction

    function automatic string state_out_name(state_out_t s);
      case (s)
        S_OUT_IDLE:
          return "OUT_IDLE";
        S_OUT_WAIT_CMD:
          return "OUT_WAIT_CMD";
        S_OUT_CALC_MEAN:
          return "OUT_CALC_MEAN";
        S_OUT_CALC_INV:
          return "OUT_CALC_INV";
        S_OUT_STREAM:
          return "OUT_STREAM";
        S_OUT_DONE:
          return "OUT_DONE";
        default:
          return "UNKNOWN";
      endcase
    endfunction

    // Accumulation phase monitor
    always_ff @(posedge clk)
    begin
      if (state_in == S_IN_ACCUM && s_axis_tvalid && s_axis_tready)
      begin
        $display("[%0t] ACCUM: beat received, element_count=%0d, tlast=%0d",
                 $time, element_count, s_axis_tlast);
      end
    end

    // Pipeline drain monitor
    always_ff @(posedge clk)
    begin
      if (state_in == S_IN_DRAIN && pipeline_done)
      begin
        $display("[%0t] DRAIN: pipeline_done asserted", $time);
      end
    end

    // Accumulator update monitor
    always_ff @(posedge clk)
    begin
      if (acc_valid_out)
      begin
        $display("[%0t] ACC_UPDATE: partial_acc[%0d] <- %h (result from adder)",
                 $time, acc_sel_delayed[FP_ADD_LATENCY-1], acc_result);
      end
    end

    // Reduce init monitor
    always_ff @(posedge clk)
    begin
      if (state_in == S_IN_REDUCE_INIT)
      begin
        $display("[%0t] REDUCE_INIT: cnt=%0d, waiting for FP_ADD_LATENCY=%0d",
                 $time, reduce_init_cnt, FP_ADD_LATENCY);
        if (reduce_init_cnt == FP_ADD_LATENCY)
        begin
          $display("[%0t] REDUCE_INIT: Loading partial_acc[0]=%h as initial reduce_acc",
                   $time, partial_acc[0]);
        end
      end
    end

    // Reduction progress monitor
    always_ff @(posedge clk)
    begin
      if (state_in == S_IN_REDUCE)
      begin
        if (tree_start)
        begin
          $display("[%0t] REDUCE: Starting Tree Reduction L1...", $time);
        end
        if (tree_l3_valid)
        begin
          $display("[%0t] REDUCE: Tree Reduction L3 Complete: result=%h",
                   $time, tree_l3_total);
        end
        if (reduce_done)
        begin
          $display("[%0t] REDUCE: DONE! total_sum=%h", $time, total_sum);
        end
      end
    end

    // Mean calculation monitor
    always_ff @(posedge clk)
    begin
      if (div_mean_valid)
      begin
        $display("[%0t] CALC_MEAN: mean = total_sum/N = %h", $time, div_mean_result);
      end
      if (eps_add_valid_out)
      begin
        $display("[%0t] CALC_MEAN: mean+eps = %h", $time, eps_add_result);
      end
      if (fast_inv_sqrt_valid)
      begin
        $display("[%0t] CALC_INV: inv_rms = 1/sqrt(mean+eps) = %h", $time, fast_inv_sqrt_result);
      end
    end

    // Stream output monitor
    always_ff @(posedge clk)
    begin
      if (state_out == S_OUT_STREAM)
      begin
        if (fifo_re)
        begin
          $display("[%0t] STREAM: fifo_re, rptr=%0d, wr_page=%0d, rd_page=%0d, stream_fed=%0d",
                   $time, fifo_rptr, wr_page, rd_page, stream_fed_count);
          $display("       Replay Read Addr: %h (Page: %b, Ptr: %h)",
                   {rd_page, fifo_rptr}, rd_page, fifo_rptr);
        end
        if (pack_valid_comb)
        begin
          $display("[%0t] STREAM: pack_valid, output_count=%0d", $time, output_count);
        end
      end
    end

    // Output count monitor
    always_ff @(posedge clk)
    begin
      // Use vector_len_reg since we are in Output FSM
      if (state_out == S_OUT_STREAM && output_count >= vector_len_reg)
      begin
        $display("[%0t] STREAM: output_count(%0d) >= MAX_VECTOR_SIZE(%0d), transitioning to DONE",
                 $time, output_count, current_vector_len);
      end
    end

    // Partial accumulator dump at key moments
    always_ff @(posedge clk)
    begin
      // Updated to use state_in and state_in_next
      if (state_in == S_IN_DRAIN && state_in_next == S_IN_REDUCE_INIT)
      begin
        $display("[%0t] === PARTIAL ACCUMULATORS AT DRAIN->REDUCE_INIT ===", $time);
        for (int i = 0; i < NUM_ACCUMULATORS; i++)
        begin
          $display("  partial_acc[%0d] = %h", i, partial_acc[i]);
        end
      end
      if (state_in == S_IN_REDUCE_INIT && state_in_next == S_IN_REDUCE)
      begin
        $display("[%0t] === PARTIAL ACCUMULATORS AT REDUCE_INIT->REDUCE ===", $time);
        for (int i = 0; i < NUM_ACCUMULATORS; i++)
        begin
          $display("  partial_acc[%0d] = %h", i, partial_acc[i]);
        end
        $display("  reduce_acc initialized to: %h", reduce_acc);
      end
    end

    // Debug for problematic beat 253 (indices 2024-2031 when dim=2048)
    // synthesis translate_off
    logic [15:0] dbg_stream_idx;
    always_ff @(posedge clk or negedge rst_n)
    begin
      if (!rst_n)
      begin
        dbg_stream_idx <= 0;
      end
      // Reset stream index when Output FSM is IDLE
      else if (state_out == S_OUT_IDLE)
      begin
        dbg_stream_idx <= 0;
      end
      else if (fifo_re)
      begin
        dbg_stream_idx <= dbg_stream_idx + NUM_LANES;
      end
    end

    // Track when gamma_valid_reg asserts for beat 253
    always_ff @(posedge clk)
    begin
      // Updated to use state_out
      if (MAX_VECTOR_SIZE == 2048 && state_out == S_OUT_STREAM)
      begin
        // Check if any of the gamma_valid_reg bits are set
        if (|gamma_valid_reg)
        begin
          for (int i = 0; i < NUM_LANES; i++)
          begin
            // Check if this could be index 2027 (beat 253, lane 3) or 2031 (beat 253, lane 7)
            if (gamma_valid_reg[i])
            begin
              $display("[%0t] DBG: gamma_valid_reg[%0d]=1, gamma_scaled_reg=%h, stream_fed=%0d",
                       $time, i, gamma_scaled_reg[i], stream_fed_count);
            end
          end
        end
        // Check quant outputs
        for (int i = 0; i < NUM_LANES; i++)
        begin
          if (quant_valid[i])
          begin
            $display("[%0t] DBG: quant_valid[%0d]=1, output_quant=%0d, output_count=%0d",
                     $time, i, output_quant[i], output_count);
          end
        end
      end
    end

    // Track the last few beats more closely
    always_ff @(posedge clk)
    begin
      // Updated to use state_out
      if (MAX_VECTOR_SIZE == 2048 && state_out == S_OUT_STREAM)
      begin
        if (stream_fed_count >= 2016 && fifo_re)
        begin
          $display("[%0t] DBG BEAT253: fifo_re at stream_fed=%0d, rptr=%0d, credit_cnt=%0d",
                   $time, stream_fed_count, fifo_rptr, credit_counter);
          $display("        replay_data_raw: [%0d, %0d, %0d, %0d, %0d, %0d, %0d, %0d]",
                   $signed(replay_data_raw[0]), $signed(replay_data_raw[1]),
                   $signed(replay_data_raw[2]), $signed(replay_data_raw[3]),
                   $signed(replay_data_raw[4]), $signed(replay_data_raw[5]),
                   $signed(replay_data_raw[6]), $signed(replay_data_raw[7]));
        end
      end
    end
    // synthesis translate_on
  end  // gen_debug
endgenerate

//===========================================================================
// FIFO Depth Monitor
//===========================================================================
// Monitor correct depth requirements for 0-8192 vector sizes
generate
  if (DEBUG_FIFO_DEPTH)
  begin : gen_depth_monitor
    integer handoff_max_usage;
    integer handoff_current_usage;
    integer output_max_usage;
    integer output_current_usage;
    wire wr = (pack_valid_comb && fifo_ready);
    wire rd = (m_axis_tvalid && m_axis_tready);

    always_ff @(posedge clk or negedge rst_n)
    begin
      if (!rst_n)
      begin
        handoff_current_usage <= 0;
        handoff_max_usage <= 0;
        output_current_usage <= 0;
        output_max_usage <= 0;
      end
      else
      begin
        // Handoff FIFO
        if (handoff_push && !handoff_pop)
        begin
          handoff_current_usage <= handoff_current_usage + 1;
          if (handoff_current_usage + 1 > handoff_max_usage)
            handoff_max_usage <= handoff_current_usage + 1;
        end
        else if (handoff_pop && !handoff_push)
        begin
          handoff_current_usage <= handoff_current_usage - 1;
        end

        // Output FIFO
        // write: pack_valid_comb && fifo_ready
        // read: m_axis_tvalid && m_axis_tready


        if (wr && !rd)
        begin
          output_current_usage <= output_current_usage + 1;
          if (output_current_usage + 1 > output_max_usage)
            output_max_usage <= output_current_usage + 1;
        end
        else if (rd && !wr)
        begin
          output_current_usage <= output_current_usage - 1;
        end
      end
    end

    // Print max usage when operation is done
    always_ff @(posedge clk)
    begin
      if (rst_n && done)
      begin
        $display("[FIFO_MONITOR] Vector Len (Param): %0d | Handoff Max: %0d | Output FIFO Max: %0d",
                 MAX_VECTOR_SIZE, handoff_max_usage, output_max_usage);
      end
    end
  end
endgenerate
