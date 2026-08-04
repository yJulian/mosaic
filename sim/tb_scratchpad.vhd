library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pkg_memmap.all;

entity tb_scratchpad is
end entity tb_scratchpad;

architecture sim of tb_scratchpad is
  constant CLK_PERIOD : time := 10 ns;

  signal clk : std_logic := '0';

  signal w_addr : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal w_data : std_logic_vector(7 downto 0) := (others => '0');
  signal w_en   : std_logic := '0';
  signal r_addr : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal r_data : std_logic_vector(7 downto 0);

  signal sim_done : boolean := false;
  signal errors   : natural := 0;
begin

  dut : entity work.scratchpad
    port map (
      clk => clk,
      w_addr => w_addr, w_data => w_data, w_en => w_en,
      r_addr => r_addr, r_data => r_data
    );

  clk_gen : process
  begin
    while not sim_done loop
      clk <= '0'; wait for CLK_PERIOD / 2;
      clk <= '1'; wait for CLK_PERIOD / 2;
    end loop;
    wait;
  end process;

  stim : process
    procedure check_byte(actual : std_logic_vector(7 downto 0); expected : natural; msg : string) is
    begin
      if to_integer(unsigned(actual)) /= expected then
        report "FAIL: " & msg & " got=" & integer'image(to_integer(unsigned(actual))) &
               " exp=" & integer'image(expected) severity error;
        errors <= errors + 1;
      else
        report "PASS: " & msg severity note;
      end if;
    end procedure;

    variable addrs : integer_vector(0 to 7) := (
      WEIGHT_BASE, WEIGHT_BASE + WEIGHT_BYTES - 1,
      ACT_BASE, ACT_BASE + ACT_BYTES - 1,
      RESULT_BASE, RESULT_BASE + RESULT_BYTES - 1,
      DEBUG_BASE, DEBUG_BASE + DEBUG_SIZE - 1
    );
  begin
    wait until rising_edge(clk);

    ------------------------------------------------------------------
    -- Test 1: write a distinct byte to a boundary address in each
    -- region, then read every one back.
    ------------------------------------------------------------------
    for i in 0 to 7 loop
      w_addr <= to_unsigned(addrs(i), ADDR_WIDTH);
      w_data <= std_logic_vector(to_unsigned((i + 1) * 17 mod 256, 8));
      w_en <= '1';
      wait until rising_edge(clk);
    end loop;
    w_en <= '0';

    for i in 0 to 7 loop
      r_addr <= to_unsigned(addrs(i), ADDR_WIDTH);
      wait until rising_edge(clk);
      wait for 1 ns;
      check_byte(r_data, (i + 1) * 17 mod 256,
        "region boundary readback at addr " & integer'image(addrs(i)));
    end loop;

    ------------------------------------------------------------------
    -- Test 2: independent read/write addressing in the same cycle
    -- (simple-dual-port). Pre-load two known addresses, then issue a
    -- write to one while reading the other in the same cycle.
    ------------------------------------------------------------------
    w_addr <= to_unsigned(WEIGHT_BASE + 5, ADDR_WIDTH);
    w_data <= x"AA";
    w_en <= '1';
    wait until rising_edge(clk);
    w_addr <= to_unsigned(WEIGHT_BASE + 6, ADDR_WIDTH);
    w_data <= x"BB";
    wait until rising_edge(clk);
    w_en <= '0';

    -- Now write a NEW value to +6 while simultaneously reading +5.
    w_addr <= to_unsigned(WEIGHT_BASE + 6, ADDR_WIDTH);
    w_data <= x"CC";
    w_en <= '1';
    r_addr <= to_unsigned(WEIGHT_BASE + 5, ADDR_WIDTH);
    wait until rising_edge(clk);
    w_en <= '0';
    wait for 1 ns;
    check_byte(r_data, 16#AA#, "SDP: read of +5 unaffected by concurrent write to +6");

    -- Confirm the write to +6 landed.
    r_addr <= to_unsigned(WEIGHT_BASE + 6, ADDR_WIDTH);
    wait until rising_edge(clk);
    wait for 1 ns;
    check_byte(r_data, 16#CC#, "SDP: write to +6 landed");

    ------------------------------------------------------------------
    report "tb_scratchpad: " & integer'image(errors) & " error(s)";
    if errors > 0 then
      report "tb_scratchpad FAILED" severity failure;
    else
      report "tb_scratchpad PASSED" severity note;
    end if;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
