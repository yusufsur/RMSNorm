# I executed this code on colab since graphviz is pain in the ass on windows

import graphviz

def generate_rmsnorm_diagram():
    """
    Generate a detailed RTL block diagram for RMSNorm hardware accelerator.
    Cross-referenced with architecture_description.txt and bdiagram.txt.
    """
    dot = graphviz.Digraph('rms_norm_accelerator', comment='RMSNorm RTL Architecture', format='png')
    
    # Global Graph Attributes
    dot.attr(rankdir='LR', compound='true', splines='ortho', nodesep='0.6', ranksep='0.8')
    dot.attr('node', shape='rect', style='filled', fillcolor='white', fontname='Consolas', fontsize='10')
    dot.attr('edge', fontname='Consolas', fontsize='8', arrowsize='0.7')
    
    # Add title and formula at the top
    dot.attr(label='RMSNorm Hardware Accelerator\\n\\n'
                   'NUM_LANES=16, configurable to 8\\n'
                   'BUS_WIDTH=512, configurable to 256\\n\\n'
                   'Formula: output[i] = (input[i] / sqrt(mean(x²) + ε)) × gamma[i]\\n',
             labelloc='t', fontsize='12', fontname='Consolas Bold')

    # =========================================================================
    # EXTERNAL INTERFACES
    # =========================================================================
    with dot.subgraph(name='cluster_ext') as ext:
        ext.attr(style='invis')
        ext.node('AXI_LITE', 'AXI4-LITE CTRL\n(s_axi_ctrl)', shape='note', fillcolor='#FFF9C4')
        ext.node('AXI_STREAM_IN', 'AXI4-STREAM IN\n(s_axis_tdata)', shape='note', fillcolor='#C8E6C9')
        ext.node('AXI_GAMMA', 'GAMMA WEIGHTS\n(s_axis_gamma)', shape='note', fillcolor='#E1BEE7')
        ext.node('AXI_STREAM_OUT', 'AXI4-STREAM OUT\n(m_axis_tdata)', shape='note', fillcolor='#C8E6C9')

    # =========================================================================
    # TOP LEVEL: AXI WRAPPER
    # =========================================================================
    with dot.subgraph(name='cluster_wrapper') as wrapper:
        wrapper.attr(label='rms_norm_axi_wrapper (Top Level)', style='dashed', color='#555555', bgcolor='#F5F5F5')
        
        # --- Wrapper Components ---
        wrapper.node('AXI_SLAVE', 'AXI Slave &\nRegister File\n(0x00-0x10)', fillcolor='#FFF176')
        wrapper.node('GAMMA_DMA', 'Gamma DMA\nController\n', fillcolor='#E1BEE7')
        wrapper.node('INTERRUPT', 'Interrupt\nLogic', shape='ellipse', fillcolor='#FFCCBC')
        
        # Connections to Wrapper components
        dot.edge('AXI_LITE', 'AXI_SLAVE', label='Addr/Data')
        dot.edge('AXI_GAMMA', 'GAMMA_DMA', label='512-bit Stream')
        dot.edge('AXI_SLAVE', 'INTERRUPT', label='reg_intr_en\nreg_intr_stat', style='dotted')

        # =====================================================================
        # CORE MODULE: RMS_NORM
        # =====================================================================
        with wrapper.subgraph(name='cluster_core') as core:
            core.attr(label='rms_norm (Core)', style='solid', color='black', bgcolor='white')

            # --- 1. MEMORY STORAGE UNITS ---
            # Replay Memory (Double Buffered)
            core.node('REPLAY_MEM', 'REPLAY MEMORY\\n(Double Buffered)\\n16 Banks x 32b\\n(8 banks for 8-lane)', shape='cylinder', fillcolor='#FFE0B2')
            
            # Gamma Memory (Banked)
            core.node('GAMMA_MEM', 'GAMMA MEMORY\\n(Banked BRAM)\\n16 Banks x 32b\\n(8 banks for 8-lane)', shape='cylinder', fillcolor='#E1BEE7')

            # --- 2. INPUT STAGE (Accumulator FSM) ---
            with core.subgraph(name='cluster_input') as inp:
                inp.attr(label='INPUT STAGE (Accumulator FSM)', style='rounded', bgcolor='#E8F5E9')
                inp.node('UNPACK', 'Unpacker\\n(512b → 16xINT32)\\n(8x for 8-lane)')
                inp.node('IN_INT2FP', 'INT2FP x16\\n(x8 for 8-lane)\\n(3 cyc)')
                inp.node('IN_REGISTER', 'Pipeline Register\\n(1 cyc)')
                inp.node('SQUARE', 'SQUARE x16\\n(x8 for 8-lane)\\n(5 cyc)')
                inp.node('ADDER_TREE', 'ADDER TREE\\n16→8→4→2→1\\n(28 cyc)')
                inp.node('ACCUM', 'Interleaved\\nAccumulators x8\\n(Round Robin)\\n(7 cyc)')
                inp.node('REDUCER', 'TREE REDUCER\\n8→4→2→1\\n(21 cyc)')
                
                # Input Data Flow
                dot.edge('UNPACK', 'IN_INT2FP', label='16 lanes')
                dot.edge('IN_INT2FP', 'IN_REGISTER', label='FP32')
                dot.edge('IN_REGISTER', 'SQUARE', label='FP32_reg')
                dot.edge('SQUARE', 'ADDER_TREE', label='x²')
                dot.edge('ADDER_TREE', 'ACCUM', label='sum_s3')
                dot.edge('ACCUM', 'REDUCER', label='partial_acc')

            # Connection: Input to Replay (Parallel Write) - Corrected to connect from UNPACK (Raw Int)
            dot.edge('UNPACK', 'REPLAY_MEM', label='Write Copy\\n(16 lanes)', color='#F57C00')

            # --- 3. HANDOFF (Decoupling) ---
            core.node('HANDOFF', 'HANDOFF FIFO\n(Depth 32, 48-bit)\n{total_sum, count}', shape='box3d', fillcolor='#B3E5FC')
            dot.edge('REDUCER', 'HANDOFF', label='Push\n(reduce_done)')

            # --- 4. OUTPUT STAGE (Normalizer FSM) ---
            with core.subgraph(name='cluster_output') as out:
                out.attr(label='OUTPUT STAGE (Normalizer FSM)', style='rounded', bgcolor='#E3F2FD')
                
                # A. Statistics Calculation Path
                with out.subgraph(name='cluster_stats') as stats:
                    stats.attr(label='Mean & Inv-Sqrt', style='dotted')
                    stats.node('N_INT2FP', 'N → FP32\n(3 cyc)')
                    stats.node('FP_DIV', 'FP_DIV\nsum / N\n(32 cyc)')
                    stats.node('ADD_EPS', 'ADD EPSILON\n+ ε (1e-5)\n(7 cyc)')
                    stats.node('QUAKE', 'QUAKE INV_SQRT\n1/sqrt(x)\n(23/45 cyc)', fillcolor='#FFCDD2')
                    stats.node('INV_RMS_REG', 'inv_rms\n', shape='box', fillcolor='#B2DFDB')
                
                # B. Normalization Pipeline
                with out.subgraph(name='cluster_norm') as norm:
                    norm.attr(label='Normalization Pipeline (16 Lanes, 8 for 8-lane)', style='dotted')
                    norm.node('REP_READ', 'Read Replay\\n(1 cyc BRAM)')
                    norm.node('REP_INT2FP', 'INT2FP x16\\n(x8 for 8-lane)\\n(3 cyc)')
                    norm.node('REP_REGISTER', 'Pipeline Register\\n(1 cyc)')
                    norm.node('NORM_MUL', 'NORM_MUL x16\\n(x8 for 8-lane)\\n(x * inv_rms)\\n(5 cyc)')
                    norm.node('GAMMA_DELAY', 'GAMMA DELAY\\n(9 cyc)', shape='box', style='dashed', fillcolor='#FFF9C4')
                    norm.node('GAMMA_MUL', 'GAMMA_MUL x16\\n(x8 for 8-lane)\\n(norm * gamma)\\n(5 cyc)')
                    norm.node('GAMMA_REGISTER', 'Pipeline Register\\n(1 cyc)')
                    norm.node('CAST', 'CAST / QUANT\\nFP32→BF16/INT8\\n(4-6 cyc)')
                    norm.node('PACKER', 'OUTPUT PACKER\\n512-bit assembly')

                # Stats Flow
                dot.edge('HANDOFF', 'FP_DIV', label='sum', constraint='true')
                dot.edge('HANDOFF', 'N_INT2FP', label='N', constraint='true')
                dot.edge('N_INT2FP', 'FP_DIV', label='n_fp32')
                dot.edge('FP_DIV', 'ADD_EPS', label='mean')
                dot.edge('ADD_EPS', 'QUAKE', label='mean+ε')
                dot.edge('QUAKE', 'INV_RMS_REG', label='fast_inv_sqrt')
                dot.edge('INV_RMS_REG', 'NORM_MUL', label='inv_rms', color='red', constraint='false')

                # Pipeline Flow
                dot.edge('REPLAY_MEM', 'REP_READ', label='Read\\n(16 lanes)')
                dot.edge('REP_READ', 'REP_INT2FP', label='replay_raw')
                dot.edge('REP_INT2FP', 'REP_REGISTER', label='replay_fp32')
                dot.edge('REP_REGISTER', 'NORM_MUL', label='x')
                dot.edge('NORM_MUL', 'GAMMA_MUL', label='1/sqrt(sum/N + e)')
                dot.edge('GAMMA_MEM', 'GAMMA_DELAY', label='Read Gamma\\n(1 cyc BRAM)')
                dot.edge('GAMMA_DELAY', 'GAMMA_MUL', label='gamma_w')
                dot.edge('GAMMA_MUL', 'GAMMA_REGISTER', label='scaled')
                dot.edge('GAMMA_REGISTER', 'CAST', label='scaled_reg')
                dot.edge('CAST', 'PACKER', label='quantized')

            # --- 5. OUTPUT FIFO SUBSYSTEM ---
            with core.subgraph(name='cluster_out_sub') as out_sub:
                out_sub.attr(label='Output Subsystem', style='filled', fillcolor='#ECEFF1')
                out_sub.node('OUT_FIFO', 'OUTPUT FIFO\n(Skid Buffer)\n256 x 512b', shape='box3d', fillcolor='#C8E6C9')
                out_sub.node('CREDIT', 'CREDIT CTRL\ncredit_available\n=counter>=OUTPUTS_PER_INPUT\n\nConsume: fifo_re\nReturn: m_axis handshake', shape='ellipse', fillcolor='#FFCC80')
                
                dot.edge('PACKER', 'OUT_FIFO', label='pack_valid')
                dot.edge('OUT_FIFO', 'CREDIT', label='credit_return\n(m_axis_tvalid\n&& m_axis_tready)', style='dashed', dir='back')
                dot.edge('CREDIT', 'REP_READ', label='credit_available\nControls the fifo_re', color='red', style='dashed', constraint='false')

    # =========================================================================
    # GLOBAL CONNECTIONS
    # =========================================================================
    dot.edge('AXI_STREAM_IN', 'UNPACK', label='512-bit Data')
    dot.edge('OUT_FIFO', 'AXI_STREAM_OUT', label='512-bit Data')
    dot.edge('GAMMA_DMA', 'GAMMA_MEM', label='DMA Write\n(Port A)', color='#8E24AA')
    dot.edge('INTERRUPT', 'AXI_STREAM_OUT', label='interrupt', style='dotted', color='#FF5722', constraint='false')
    
    # Control Signals from Wrapper
    dot.edge('AXI_SLAVE', 'ADD_EPS', label='reg_epsilon', style='dotted', constraint='false')
    dot.edge('AXI_SLAVE', 'UNPACK', label='core_start', style='dotted', constraint='false')
    dot.edge('OUT_FIFO', 'INTERRUPT', label='core_done', style='dotted', color='#FF5722', constraint='false')
    
    # Render the diagram
    dot.render(filename='rms_norm_accelerator', directory='.', format='png', cleanup=True)
    print("Block diagram generated successfully: rms_norm_accelerator.png")
    print("Configuration: NUM_LANES=16 (configurable to 8)")
    print("\n" + "="*80)
    print(dot.source)
    print("="*80)
    return dot

# Execute generation
if __name__ == "__main__":
    generate_rmsnorm_diagram()