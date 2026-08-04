library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_sync_fifo is
end entity tb_sync_fifo;

architecture sim of tb_sync_fifo is
  constant CLK_PERIOD : time := 10 ns;
  constant DEPTH      : natural := 4;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal wr_en   : std_logic := '0';
  signal wr_data : std_logic_vector(7 downto 0) := (others => '0');
  signal full    : std_logic;
  signal rd_en   : std_logic := '0';
  signal rd_data : std_logic_vector(7 downto 0);
  signal empty   : std_logic;

  signal sim_done : boolean := false;
  signal errors   : natural := 0;
begin

  dut : entity work.sync_fifo
    generic map (WIDTH => 8, DEPTH => DEPTH)
    port map (
      clk => clk, rst => rst,
      wr_en => wr_en, wr_data => wr_data, full => full,
      rd_en => rd_en, rd_data => rd_data, empty => empty
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
    procedure check_std(actual, expected : std_logic; msg : string) is
    begin
      if actual /= expected then
        report "FAIL: " & msg severity error;
        errors <= errors + 1;
      else
        report "PASS: " & msg severity note;
      end if;
    end procedure;

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
  begin
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    check_std(empty, '1', "empty after reset");
    check_std(full, '0', "not full after reset");

    ------------------------------------------------------------------
    -- Fill to depth, verify full asserts, verify overfill write is a
    -- silent no-op (dropped, not corrupting existing entries).
    ------------------------------------------------------------------
    for i in 0 to DEPTH - 1 loop
      wr_data <= std_logic_vector(to_unsigned(i * 10 + 1, 8));
      wr_en <= '1';
      wait until rising_edge(clk);
    end loop;
    wr_en <= '0';
    wait for 1 ns;
    check_std(full, '1', "full after filling to DEPTH");

    -- attempted overfill
    wr_data <= x"FF";
    wr_en <= '1';
    wait until rising_edge(clk);
    wr_en <= '0';
    wait for 1 ns;
    check_std(full, '1', "still full after attempted overfill");

    ------------------------------------------------------------------
    -- Drain in FIFO order.
    ------------------------------------------------------------------
    for i in 0 to DEPTH - 1 loop
      rd_en <= '1';
      wait until rising_edge(clk);
      rd_en <= '0';
      wait for 1 ns;
      check_byte(rd_data, i * 10 + 1, "drain order #" & integer'image(i));
    end loop;
    wait for 1 ns;
    check_std(empty, '1', "empty after full drain");

    -- attempted underflow read is a no-op
    rd_en <= '1';
    wait until rising_edge(clk);
    rd_en <= '0';
    wait for 1 ns;
    check_std(empty, '1', "still empty after attempted underflow read");

    ------------------------------------------------------------------
    -- Simultaneous read+write (wrap-around exercise).
    ------------------------------------------------------------------
    wr_data <= x"11"; wr_en <= '1';
    wait until rising_edge(clk);
    wr_data <= x"22";
    wait until rising_edge(clk);
    wr_en <= '0';
    -- now count=2; issue simultaneous rd+wr for a few cycles
    wr_data <= x"33"; wr_en <= '1'; rd_en <= '1';
    wait until rising_edge(clk);
    wr_data <= x"44";
    wait until rising_edge(clk);
    wr_en <= '0'; rd_en <= '0';
    wait for 1 ns;
    check_byte(rd_data, 16#22#, "simultaneous rd+wr last read = 0x22");

    -- drain remaining 2 entries (0x33, 0x44)
    rd_en <= '1';
    wait until rising_edge(clk);
    wait for 1 ns;
    check_byte(rd_data, 16#33#, "post-wrap drain #1");
    wait until rising_edge(clk);
    wait for 1 ns;
    check_byte(rd_data, 16#44#, "post-wrap drain #2");
    rd_en <= '0';

    ------------------------------------------------------------------
    report "tb_sync_fifo: " & integer'image(errors) & " error(s)";
    if errors > 0 then
      report "tb_sync_fifo FAILED" severity failure;
    else
      report "tb_sync_fifo PASSED" severity note;
    end if;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
