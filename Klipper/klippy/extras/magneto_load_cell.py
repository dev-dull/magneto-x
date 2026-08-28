class PrinterLoadCellDigitalOut:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.pin_control = self.printer.lookup_object('pins')
        self.reset_pin = config.get('pin')
        self.gcode = self.printer.lookup_object('gcode')
        self.load_cell_reset_pin = None
        self.gcode.register_command('LC28', self.cmd_clear_load_cell)
        self.gcode.register_command('LL28', self.cmd_set_pin_low)
        self.gcode.register_command('LH28', self.cmd_set_pin_high)
        self.load_cell_reset_pin = self.pin_control.setup_pin('digital_out', self.reset_pin)
        if self.load_cell_reset_pin is not None:
            self.load_cell_reset_pin.setup_max_duration(0) 
            self.load_cell_reset_pin.setup_start_value(1,1,False)
            self.gcode.respond_info("init magneto load cell")
            self.gcode.respond_info(self.reset_pin)
        else:
            self.gcode.respond_info("init magneto load cell failed!!")


    def _set_pin(self, gcmd, value):
        # Schedule the pin change in print time, ordered after any
        # queued motion (same pattern as upstream output_pin), rather
        # than at an unsynchronized wall-clock offset.
        if self.load_cell_reset_pin is not None:
            toolhead = self.printer.lookup_object('toolhead')
            print_time = toolhead.get_last_move_time()
            self.load_cell_reset_pin.set_digital(print_time + 0.1, value)
            toolhead.dwell(0.1)

    def cmd_set_pin_high(self, gcmd):
        self._set_pin(gcmd, 1)

    def cmd_set_pin_low(self, gcmd):
        self._set_pin(gcmd, 0)

    def cmd_clear_load_cell(self, gcmd):
        if self.load_cell_reset_pin is not None:
            # Ensure all buffered moves have completed before taring so
            # the tare captures a static (not dynamic) load.
            toolhead = self.printer.lookup_object('toolhead')
            toolhead.wait_moves()
        self.clear_load_cell()

    def set_cell(self, printime, value):
        if self.load_cell_reset_pin is not None:
            self.load_cell_reset_pin.set_digital(printime, value)
    

    def clear_load_cell(self):
        # Schedule the tare pulse in print time, based on the end of
        # the motion queue (get_last_move_time() flushes lookahead), so
        # the reset line cannot toggle while a previously queued move
        # is still in progress.  The relative low/high offsets of the
        # original wall-clock implementation are preserved.
        if self.load_cell_reset_pin is not None:
            toolhead = self.printer.lookup_object('toolhead')
            print_time = toolhead.get_last_move_time()
            self.load_cell_reset_pin.set_digital(print_time + 0.1, 0)
            self.load_cell_reset_pin.set_digital(print_time + 0.5, 1)
            # Keep any subsequently queued motion (e.g. the G28 Z
            # probing descent) after the release edge of the pulse.
            toolhead.dwell(0.7)



def load_config(config):
    return PrinterLoadCellDigitalOut(config)
