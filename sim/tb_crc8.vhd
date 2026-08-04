library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- Cross-checks crc8.vhd against reference values independently computed
-- in Python (poly 0x07, init 0x00, MSB-first, no reflection -- see the
-- generation snippet in the task history / docs/protocol.md).
entity tb_crc8 is
end entity tb_crc8;

architecture sim of tb_crc8 is
  constant CLK_PERIOD : time := 10 ns;

  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal init       : std_logic := '0';
  signal byte_in    : std_logic_vector(7 downto 0) := (others => '0');
  signal byte_valid : std_logic := '0';
  signal crc_out    : std_logic_vector(7 downto 0);

  signal sim_done : boolean := false;
  signal errors   : natural := 0;

  type byte_arr_t is array (natural range <>) of natural;
begin

  dut : entity work.crc8
    port map (
      clk => clk, rst => rst,
      init => init, byte_in => byte_in, byte_valid => byte_valid,
      crc_out => crc_out
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
    procedure check_crc(expected : natural; msg : string) is
    begin
      if to_integer(unsigned(crc_out)) /= expected then
        report "FAIL: " & msg & " got=" & integer'image(to_integer(unsigned(crc_out))) &
               " exp=" & integer'image(expected) severity error;
        errors <= errors + 1;
      else
        report "PASS: " & msg severity note;
      end if;
    end procedure;

    procedure run_case(data : byte_arr_t; expected : natural; msg : string) is
    begin
      init <= '1';
      wait until rising_edge(clk);
      init <= '0';
      for i in data'range loop
        byte_in <= std_logic_vector(to_unsigned(data(i), 8));
        byte_valid <= '1';
        wait until rising_edge(clk);
      end loop;
      byte_valid <= '0';
      wait for 1 ns;
      check_crc(expected, msg);
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    run_case(byte_arr_t'(1 to 0 => 0), 16#00#, "empty");
    run_case(byte_arr_t'(0 => 0), 16#00#, "[0x00]");
    run_case(byte_arr_t'(0 => 255), 16#F3#, "[0xFF]");
    run_case(byte_arr_t'(1, 0), 16#15#, "[0x01,0x00]");
    run_case(byte_arr_t'(3, 2, 17, 34), 16#40#, "[0x03,0x02,0x11,0x22]");

    run_case(byte_arr_t'(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                          16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
                          29, 30, 31, 32, 33, 34, 35),
             16#FF#, "[0..35]");

    ------------------------------------------------------------------
    report "tb_crc8: " & integer'image(errors) & " error(s)";
    if errors > 0 then
      report "tb_crc8 FAILED" severity failure;
    else
      report "tb_crc8 PASSED" severity note;
    end if;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
