# Zedboard Rev C/D  (XC7Z020-CLG484-1).  Pin/IOSTANDARD taken from the Zedboard
# reference constraints -- double-check against your board revision's XDC.

# 100 MHz PL clock
set_property PACKAGE_PIN Y9 [get_ports GCLK]
set_property IOSTANDARD LVCMOS33 [get_ports GCLK]
create_clock -period 10.000 -name GCLK [get_ports GCLK]

# LEDs LD0..LD7 (bank 33, 3.3 V)
set_property PACKAGE_PIN T22 [get_ports {LD[0]}]
set_property PACKAGE_PIN T21 [get_ports {LD[1]}]
set_property PACKAGE_PIN U22 [get_ports {LD[2]}]
set_property PACKAGE_PIN U21 [get_ports {LD[3]}]
set_property PACKAGE_PIN V22 [get_ports {LD[4]}]
set_property PACKAGE_PIN W22 [get_ports {LD[5]}]
set_property PACKAGE_PIN U19 [get_ports {LD[6]}]
set_property PACKAGE_PIN U14 [get_ports {LD[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {LD[*]}]

# Slide switches SW0..SW7 (bank 35, VADJ = 1.8 V default)
set_property PACKAGE_PIN F22 [get_ports {SW[0]}]
set_property PACKAGE_PIN G22 [get_ports {SW[1]}]
set_property PACKAGE_PIN H22 [get_ports {SW[2]}]
set_property PACKAGE_PIN F21 [get_ports {SW[3]}]
set_property PACKAGE_PIN H19 [get_ports {SW[4]}]
set_property PACKAGE_PIN H18 [get_ports {SW[5]}]
set_property PACKAGE_PIN H17 [get_ports {SW[6]}]
set_property PACKAGE_PIN M15 [get_ports {SW[7]}]
set_property IOSTANDARD LVCMOS18 [get_ports {SW[*]}]

# Push buttons (bank 34, 1.8 V): BTNC = P16, BTNU = T18
set_property PACKAGE_PIN P16 [get_ports BTNC]
set_property PACKAGE_PIN T18 [get_ports BTNU]
set_property IOSTANDARD LVCMOS18 [get_ports {BTNC BTNU}]

# Async human inputs: no timing to check
set_false_path -from [get_ports {BTNC BTNU SW[*]}]
