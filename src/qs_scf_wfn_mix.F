!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2024 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Does all kind of post scf calculations for GPW/GAPW
!> \par History
!>      Started as a copy from the relevant part of qs_scf
!> \author Joost VandeVondele (10.2003)
! **************************************************************************************************
MODULE qs_scf_wfn_mix
   USE cp_dbcsr_api,                    ONLY: dbcsr_p_type
   USE cp_dbcsr_operations,             ONLY: copy_fm_to_dbcsr
   USE cp_files,                        ONLY: close_file,&
                                              open_file
   USE cp_fm_basic_linalg,              ONLY: cp_fm_scale_and_add
   USE cp_fm_struct,                    ONLY: cp_fm_struct_create,&
                                              cp_fm_struct_release,&
                                              cp_fm_struct_type
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_release,&
                                              cp_fm_to_fm,&
                                              cp_fm_type
   USE input_constants,                 ONLY: wfn_mix_orig_external,&
                                              wfn_mix_orig_occ,&
                                              wfn_mix_orig_virtual
   USE input_section_types,             ONLY: section_vals_get,&
                                              section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: default_path_length,&
                                              dp
   USE message_passing,                 ONLY: mp_para_env_type
   USE particle_types,                  ONLY: particle_type
   USE qs_kind_types,                   ONLY: qs_kind_type
   USE qs_mo_io,                        ONLY: read_mos_restart_low,&
                                              write_mo_set_to_restart
   USE qs_mo_methods,                   ONLY: calculate_orthonormality
   USE qs_mo_types,                     ONLY: deallocate_mo_set,&
                                              duplicate_mo_set,&
                                              mo_set_type
   USE qs_scf_types,                    ONLY: qs_scf_env_type,&
                                              special_diag_method_nr
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   ! Global parameters
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_scf_wfn_mix'
   PUBLIC :: wfn_mix

CONTAINS

! **************************************************************************************************
!> \brief writes a new 'mixed' set of mos to restart file, without touching the current MOs
!> \param mos ...
!> \param particle_set ...
!> \param dft_section ...
!> \param qs_kind_set ...
!> \param para_env ...
!> \param output_unit ...
!> \param unoccupied_orbs ...
!> \param scf_env ...
!> \param matrix_s ...
!> \param marked_states ...
!> \param for_rtp ...
! **************************************************************************************************
   SUBROUTINE wfn_mix(mos, particle_set, dft_section, qs_kind_set, para_env, output_unit, &
                      unoccupied_orbs, scf_env, matrix_s, marked_states, for_rtp)

      TYPE(mo_set_type), DIMENSION(:), POINTER           :: mos
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(section_vals_type), POINTER                   :: dft_section
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(mp_para_env_type), POINTER                    :: para_env
      INTEGER                                            :: output_unit
      TYPE(cp_fm_type), DIMENSION(:), INTENT(IN), &
         OPTIONAL, POINTER                               :: unoccupied_orbs
      TYPE(qs_scf_env_type), OPTIONAL, POINTER           :: scf_env
      TYPE(dbcsr_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: matrix_s
      INTEGER, DIMENSION(:, :, :), OPTIONAL, POINTER     :: marked_states
      LOGICAL, OPTIONAL                                  :: for_rtp

      CHARACTER(len=*), PARAMETER                        :: routineN = 'wfn_mix'

      CHARACTER(LEN=default_path_length)                 :: read_file_name
      INTEGER :: handle, i_rep, ispin, mark_ind, mark_number, n_rep, orig_mo_index, &
         orig_spin_index, orig_type, restart_unit, result_mo_index, result_spin_index
      LOGICAL                                            :: explicit, is_file, my_for_rtp, &
                                                            overwrite_mos, reverse_mo_index
      REAL(KIND=dp)                                      :: orig_scale, orthonormality, result_scale
      TYPE(cp_fm_struct_type), POINTER                   :: fm_struct_vector
      TYPE(cp_fm_type)                                   :: matrix_x, matrix_y
      TYPE(mo_set_type), ALLOCATABLE, DIMENSION(:)       :: mos_new, mos_orig_ext
      TYPE(section_vals_type), POINTER                   :: update_section, wfn_mix_section

      CALL timeset(routineN, handle)
      wfn_mix_section => section_vals_get_subs_vals(dft_section, "PRINT%WFN_MIX")
      CALL section_vals_get(wfn_mix_section, explicit=explicit)

      ! only perform action if explicitly required
      IF (explicit) THEN

         IF (PRESENT(for_rtp)) THEN
            my_for_rtp = for_rtp
         ELSE
            my_for_rtp = .FALSE.
         END IF

         IF (output_unit > 0) THEN
            WRITE (output_unit, '()')
            WRITE (output_unit, '(T2,A)') "Performing wfn mixing"
            WRITE (output_unit, '(T2,A)') "====================="
         END IF

         ALLOCATE (mos_new(SIZE(mos)))
         DO ispin = 1, SIZE(mos)
            CALL duplicate_mo_set(mos_new(ispin), mos(ispin))
         END DO

         ! a single vector matrix structure
         NULLIFY (fm_struct_vector)
         CALL cp_fm_struct_create(fm_struct_vector, template_fmstruct=mos(1)%mo_coeff%matrix_struct, &
                                  ncol_global=1)
         CALL cp_fm_create(matrix_x, fm_struct_vector, name="x")
         CALL cp_fm_create(matrix_y, fm_struct_vector, name="y")
         CALL cp_fm_struct_release(fm_struct_vector)

         update_section => section_vals_get_subs_vals(wfn_mix_section, "UPDATE")
         CALL section_vals_get(update_section, n_repetition=n_rep)
         CALL section_vals_get(update_section, explicit=explicit)
         IF (.NOT. explicit) n_rep = 0

         ! Mix the MOs as : y = ay + bx
         DO i_rep = 1, n_rep
            ! The occupied MO that will be modified or saved, 'y'
            CALL section_vals_val_get(update_section, "RESULT_MO_INDEX", i_rep_section=i_rep, i_val=result_mo_index)
            CALL section_vals_val_get(update_section, "RESULT_MARKED_STATE", i_rep_section=i_rep, i_val=mark_number)
            CALL section_vals_val_get(update_section, "RESULT_SPIN_INDEX", i_rep_section=i_rep, i_val=result_spin_index)
            ! result_scale is the 'a' coefficient
            CALL section_vals_val_get(update_section, "RESULT_SCALE", i_rep_section=i_rep, r_val=result_scale)

            mark_ind = 1
            IF (mark_number .GT. 0) result_mo_index = marked_states(mark_number, result_spin_index, mark_ind)

            ! The MO that will be added to the previous one, 'x'
            CALL section_vals_val_get(update_section, "ORIG_TYPE", i_rep_section=i_rep, &
                                      i_val=orig_type)
            CALL section_vals_val_get(update_section, "ORIG_MO_INDEX", i_rep_section=i_rep, i_val=orig_mo_index)
            CALL section_vals_val_get(update_section, "ORIG_MARKED_STATE", i_rep_section=i_rep, i_val=mark_number)
            CALL section_vals_val_get(update_section, "ORIG_SPIN_INDEX", i_rep_section=i_rep, i_val=orig_spin_index)
            ! orig_scal is the 'b' coefficient
            CALL section_vals_val_get(update_section, "ORIG_SCALE", i_rep_section=i_rep, r_val=orig_scale)

            IF (orig_type == wfn_mix_orig_virtual) mark_ind = 2
            IF (mark_number .GT. 0) orig_mo_index = marked_states(mark_number, orig_spin_index, mark_ind)

            CALL section_vals_val_get(wfn_mix_section, "OVERWRITE_MOS", l_val=overwrite_mos)

            CALL section_vals_val_get(update_section, "REVERSE_MO_INDEX", l_val=reverse_mo_index)

            ! First get a copy of the proper orig
            ! Origin is in the MO matrix
            IF (orig_type == wfn_mix_orig_occ) THEN
               IF (reverse_mo_index) THEN
                  CALL cp_fm_to_fm(mos(orig_spin_index)%mo_coeff, matrix_x, 1, &
                                   orig_mo_index, 1)
               ELSE
                  CALL cp_fm_to_fm(mos(orig_spin_index)%mo_coeff, matrix_x, 1, &
                                   mos(orig_spin_index)%nmo - orig_mo_index + 1, 1)
               END IF
               ! Orgin is in the virtual matrix
            ELSE IF (orig_type == wfn_mix_orig_virtual) THEN
               IF (.NOT. ASSOCIATED(unoccupied_orbs)) &
                  CALL cp_abort(__LOCATION__, &
                                "If ORIG_TYPE is set to VIRTUAL, the array unoccupied_orbs must be associated! "// &
                                "For instance, ask in the SCF section to compute virtual orbitals after the GS optimization.")
               CALL cp_fm_to_fm(unoccupied_orbs(orig_spin_index), matrix_x, 1, orig_mo_index, 1)

               ! Orgin is to be read from an external .wfn file
            ELSE IF (orig_type == wfn_mix_orig_external) THEN
               CALL section_vals_val_get(update_section, "ORIG_EXT_FILE_NAME", i_rep_section=i_rep, &
                                         c_val=read_file_name)
               IF (read_file_name == "EMPTY") &
                  CALL cp_abort(__LOCATION__, &
                                "If ORIG_TYPE is set to EXTERNAL, a file name should be set in ORIG_EXT_FILE_NAME "// &
                                "so that it can be used as the orginal MO.")

               ALLOCATE (mos_orig_ext(SIZE(mos)))
               DO ispin = 1, SIZE(mos)
                  CALL duplicate_mo_set(mos_orig_ext(ispin), mos(ispin))
               END DO

               IF (para_env%is_source()) THEN
                  INQUIRE (FILE=TRIM(read_file_name), exist=is_file)
                  IF (.NOT. is_file) &
                     CALL cp_abort(__LOCATION__, &
                                   "Reference file not found! Name of the file CP2K looked for: "//TRIM(read_file_name))

                  CALL open_file(file_name=read_file_name, &
                                 file_action="READ", &
                                 file_form="UNFORMATTED", &
                                 file_status="OLD", &
                                 unit_number=restart_unit)
               END IF
               CALL read_mos_restart_low(mos_orig_ext, para_env=para_env, qs_kind_set=qs_kind_set, &
                                         particle_set=particle_set, natom=SIZE(particle_set, 1), &
                                         rst_unit=restart_unit)
               IF (para_env%is_source()) CALL close_file(unit_number=restart_unit)

               IF (reverse_mo_index) THEN
                  CALL cp_fm_to_fm(mos_orig_ext(orig_spin_index)%mo_coeff, matrix_x, 1, &
                                   orig_mo_index, 1)
               ELSE
                  CALL cp_fm_to_fm(mos_orig_ext(orig_spin_index)%mo_coeff, matrix_x, 1, &
                                   mos_orig_ext(orig_spin_index)%nmo - orig_mo_index + 1, 1)
               END IF
               DO ispin = 1, SIZE(mos_orig_ext)
                  CALL deallocate_mo_set(mos_orig_ext(ispin))
               END DO
               DEALLOCATE (mos_orig_ext)
            END IF

            ! Second, get a copy of the target
            IF (reverse_mo_index) THEN
               CALL cp_fm_to_fm(mos_new(result_spin_index)%mo_coeff, matrix_y, &
                                1, result_mo_index, 1)
            ELSE
               CALL cp_fm_to_fm(mos_new(result_spin_index)%mo_coeff, matrix_y, &
                                1, mos_new(result_spin_index)%nmo - result_mo_index + 1, 1)
            END IF

            ! Third, perform the mix
            CALL cp_fm_scale_and_add(result_scale, matrix_y, orig_scale, matrix_x)

            ! and copy back in the result mos
            IF (reverse_mo_index) THEN
               CALL cp_fm_to_fm(matrix_y, mos_new(result_spin_index)%mo_coeff, &
                                1, 1, result_mo_index)
            ELSE
               CALL cp_fm_to_fm(matrix_y, mos_new(result_spin_index)%mo_coeff, &
                                1, 1, mos_new(result_spin_index)%nmo - result_mo_index + 1)
            END IF
         END DO

         CALL cp_fm_release(matrix_x)
         CALL cp_fm_release(matrix_y)

         IF (my_for_rtp) THEN
            DO ispin = 1, SIZE(mos_new)
               CALL cp_fm_to_fm(mos_new(ispin)%mo_coeff, mos(ispin)%mo_coeff)
               IF (mos_new(1)%use_mo_coeff_b) &
                  CALL copy_fm_to_dbcsr(mos_new(ispin)%mo_coeff, mos_new(ispin)%mo_coeff_b)
               IF (mos(1)%use_mo_coeff_b) &
                  CALL copy_fm_to_dbcsr(mos_new(ispin)%mo_coeff, mos(ispin)%mo_coeff_b)
            END DO
         ELSE
            IF (scf_env%method == special_diag_method_nr) THEN
               CALL calculate_orthonormality(orthonormality, mos)
            ELSE
               CALL calculate_orthonormality(orthonormality, mos, matrix_s(1)%matrix)
            END IF

            IF (output_unit > 0) THEN
               WRITE (output_unit, '()')
               WRITE (output_unit, '(T2,A,T61,E20.4)') &
                  "Maximum deviation from MO S-orthonormality", orthonormality
               WRITE (output_unit, '(T2,A)') "Writing new MOs to file"
            END IF

            ! *** Write WaveFunction restart file ***

            DO ispin = 1, SIZE(mos_new)
               IF (overwrite_mos) THEN
                  CALL cp_fm_to_fm(mos_new(ispin)%mo_coeff, mos(ispin)%mo_coeff)
                  IF (mos_new(1)%use_mo_coeff_b) &
                     CALL copy_fm_to_dbcsr(mos_new(ispin)%mo_coeff, mos_new(ispin)%mo_coeff_b)
               END IF
               IF (mos(1)%use_mo_coeff_b) &
                  CALL copy_fm_to_dbcsr(mos_new(ispin)%mo_coeff, mos(ispin)%mo_coeff_b)
            END DO
            CALL write_mo_set_to_restart(mos_new, particle_set, dft_section=dft_section, qs_kind_set=qs_kind_set)
         END IF

         DO ispin = 1, SIZE(mos_new)
            CALL deallocate_mo_set(mos_new(ispin))
         END DO
         DEALLOCATE (mos_new)

      END IF

      CALL timestop(handle)

   END SUBROUTINE wfn_mix

END MODULE qs_scf_wfn_mix
