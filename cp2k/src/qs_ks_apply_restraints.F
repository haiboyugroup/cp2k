!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright (C) 2000 - 2017  CP2K developers group                                               !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Set of routines to apply restraints to the KS hamiltonian
! **************************************************************************************************
MODULE qs_ks_apply_restraints
   USE cp_control_types,                ONLY: becke_restraint_type,&
                                              dft_control_type
   USE cp_dbcsr_operations,             ONLY: copy_dbcsr_to_fm,&
                                              copy_fm_to_dbcsr
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_p_type,&
                                              cp_fm_type
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_copy,&
                                              dbcsr_init,&
                                              dbcsr_p_type,&
                                              dbcsr_set
   USE et_coupling,                     ONLY: becke_restraint
   USE kinds,                           ONLY: dp
   USE mulliken,                        ONLY: mulliken_restraint
   USE pw_methods,                      ONLY: pw_scale
   USE pw_pool_types,                   ONLY: pw_pool_create_pw,&
                                              pw_pool_type
   USE pw_types,                        ONLY: REALDATA3D,&
                                              REALSPACE
   USE qs_energy_types,                 ONLY: qs_energy_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_integrate_potential,          ONLY: integrate_v_rspace
   USE qs_mo_types,                     ONLY: get_mo_set,&
                                              mo_set_p_type
   USE qs_rho_types,                    ONLY: qs_rho_get,&
                                              qs_rho_type
   USE s_square_methods,                ONLY: s2_restraint
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   LOGICAL, PARAMETER :: debug_this_module = .TRUE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_ks_apply_restraints'

   PUBLIC :: qs_ks_becke_restraint, qs_ks_mulliken_restraint, qs_ks_s2_restraint

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param qs_env ...
!> \param auxbas_pw_pool ...
!> \param calculate_forces ...
!> \param matrix_s ...
!> \param becke ...
! **************************************************************************************************
   SUBROUTINE qs_ks_becke_restraint(qs_env, auxbas_pw_pool, calculate_forces, matrix_s, becke)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(pw_pool_type), POINTER                        :: auxbas_pw_pool
      LOGICAL, INTENT(in)                                :: calculate_forces
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_s
      TYPE(becke_restraint_type), POINTER                :: becke

      CHARACTER(LEN=*), PARAMETER :: routineN = 'qs_ks_becke_restraint', &
         routineP = moduleN//':'//routineN

      REAL(KIND=dp)                                      :: inv_vol
      TYPE(dft_control_type), POINTER                    :: dft_control

      NULLIFY (dft_control)
      CALL get_qs_env(qs_env, dft_control=dft_control)

      IF (dft_control%qs_control%becke_restraint) THEN
         ! Test no k-points
         CPASSERT(SIZE(matrix_s, 2) == 1)
         !***** Check if becke potential is needed to constrain charges *****
         becke => dft_control%qs_control%becke_control
         IF (becke%need_pot .OR. calculate_forces) THEN
            CALL pw_pool_create_pw(auxbas_pw_pool, becke%becke_pot%pw, use_data=REALDATA3D, &
                                   in_space=REALSPACE)
            CALL becke_restraint(qs_env, becke_const=becke%becke_pot, calc_pot=.TRUE., &
                                 calculate_forces=calculate_forces)
            CALL pw_scale(becke%becke_pot%pw, becke%becke_pot%pw%pw_grid%dvol)
            becke%need_pot = .FALSE.
         ELSE
            inv_vol = 1.0_dp/becke%becke_pot%pw%pw_grid%dvol
            CALL pw_scale(becke%becke_pot%pw, inv_vol)
            CALL becke_restraint(qs_env, becke%becke_pot, calc_pot=.FALSE., &
                                 calculate_forces=calculate_forces)
            CALL pw_scale(becke%becke_pot%pw, becke%becke_pot%pw%pw_grid%dvol)
         ENDIF

         IF (dft_control%qs_control%et_coupling_calc) THEN
            IF (qs_env%et_coupling%keep_matrix) THEN
               IF (qs_env%et_coupling%first_run) THEN
                  NULLIFY (qs_env%et_coupling%rest_mat(1)%matrix)
                  ALLOCATE (qs_env%et_coupling%rest_mat(1)%matrix)
                  CALL dbcsr_init(qs_env%et_coupling%rest_mat(1)%matrix)
                  CALL dbcsr_copy(qs_env%et_coupling%rest_mat(1)%matrix, matrix_s(1, 1)%matrix, &
                                  name="ET_RESTRAINT_MATRIX_A")
                  CALL dbcsr_set(qs_env%et_coupling%rest_mat(1)%matrix, 0.0_dp)
                  CALL integrate_v_rspace(becke%becke_pot, &
                                          hmat=qs_env%et_coupling%rest_mat(1), &
                                          qs_env=qs_env, calculate_forces=.FALSE.)
                  qs_env%et_coupling%order_p = dft_control%qs_control%becke_control%becke_order_p
                  qs_env%et_coupling%e1 = dft_control%qs_control%becke_control%strength
                  qs_env%et_coupling%keep_matrix = .FALSE.
               ELSE
                  NULLIFY (qs_env%et_coupling%rest_mat(2)%matrix)
                  ALLOCATE (qs_env%et_coupling%rest_mat(2)%matrix)
                  CALL dbcsr_init(qs_env%et_coupling%rest_mat(2)%matrix)
                  CALL dbcsr_copy(qs_env%et_coupling%rest_mat(2)%matrix, matrix_s(1, 1)%matrix, &
                                  name="ET_RESTRAINT_MATRIX_B")
                  CALL dbcsr_set(qs_env%et_coupling%rest_mat(2)%matrix, 0.0_dp)
                  CALL integrate_v_rspace(becke%becke_pot, &
                                          hmat=qs_env%et_coupling%rest_mat(2), &
                                          qs_env=qs_env, calculate_forces=.FALSE.)

               END IF
            END IF
         END IF
      END IF
   END SUBROUTINE qs_ks_becke_restraint

! **************************************************************************************************
!> \brief ...
!> \param energy ...
!> \param dft_control ...
!> \param just_energy ...
!> \param para_env ...
!> \param ks_matrix ...
!> \param matrix_s ...
!> \param rho ...
!> \param mulliken_order_p ...
! **************************************************************************************************
   SUBROUTINE qs_ks_mulliken_restraint(energy, dft_control, just_energy, para_env, &
                                       ks_matrix, matrix_s, rho, mulliken_order_p)

      TYPE(qs_energy_type), POINTER                      :: energy
      TYPE(dft_control_type), POINTER                    :: dft_control
      LOGICAL, INTENT(in)                                :: just_energy
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: ks_matrix, matrix_s
      TYPE(qs_rho_type), POINTER                         :: rho
      REAL(KIND=dp)                                      :: mulliken_order_p

      CHARACTER(LEN=*), PARAMETER :: routineN = 'qs_ks_mulliken_restraint', &
         routineP = moduleN//':'//routineN

      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: ksmat, rho_ao

      energy%mulliken = 0.0_dp

      IF (dft_control%qs_control%mulliken_restraint) THEN

         ! Test no k-points
         CPASSERT(SIZE(matrix_s, 2) == 1)

         CALL qs_rho_get(rho, rho_ao=rho_ao)

         IF (just_energy) THEN
            CALL mulliken_restraint(dft_control%qs_control%mulliken_restraint_control, &
                                    para_env, matrix_s(1, 1)%matrix, rho_ao, energy=energy%mulliken, &
                                    order_p=mulliken_order_p)
         ELSE
            ksmat => ks_matrix(:, 1)
            CALL mulliken_restraint(dft_control%qs_control%mulliken_restraint_control, &
                                    para_env, matrix_s(1, 1)%matrix, rho_ao, energy=energy%mulliken, &
                                    ks_matrix=ksmat, order_p=mulliken_order_p)
         ENDIF

      ENDIF

   END SUBROUTINE qs_ks_mulliken_restraint

! **************************************************************************************************
!> \brief ...
!> \param dft_control ...
!> \param qs_env ...
!> \param matrix_s ...
!> \param energy ...
!> \param calculate_forces ...
!> \param just_energy ...
! **************************************************************************************************
   SUBROUTINE qs_ks_s2_restraint(dft_control, qs_env, matrix_s, &
                                 energy, calculate_forces, just_energy)

      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_s
      TYPE(qs_energy_type), POINTER                      :: energy
      LOGICAL, INTENT(in)                                :: calculate_forces, just_energy

      CHARACTER(LEN=*), PARAMETER :: routineN = 'qs_ks_s2_restraint', &
         routineP = moduleN//':'//routineN

      INTEGER                                            :: i
      TYPE(cp_fm_p_type), DIMENSION(:), POINTER          :: fm_mo_derivs
      TYPE(cp_fm_type), POINTER                          :: mo_coeff
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: mo_derivs, smat
      TYPE(mo_set_p_type), DIMENSION(:), POINTER         :: mo_array

      NULLIFY (fm_mo_derivs, mo_array, mo_coeff, mo_derivs)

      IF (dft_control%qs_control%s2_restraint) THEN
         ! Test no k-points
         CPASSERT(SIZE(matrix_s, 2) == 1)
         ! adds s2_restraint energy and orbital derivatives
         CPASSERT(dft_control%nspins == 2)
         CPASSERT(qs_env%requires_mo_derivs)
         ! forces are not implemented (not difficult, but ... )
         CPASSERT(.NOT. calculate_forces)
         CALL get_qs_env(qs_env, mo_derivs=mo_derivs, mos=mo_array)

         ALLOCATE (fm_mo_derivs(SIZE(mo_derivs, 1))) !fm->dbcsr
         DO i = 1, SIZE(mo_derivs, 1) !fm->dbcsr
            CALL get_mo_set(mo_set=mo_array(i)%mo_set, mo_coeff=mo_coeff) !fm->dbcsr
            CALL cp_fm_create(fm_mo_derivs(i)%matrix, mo_coeff%matrix_struct) !fm->dbcsr
            CALL copy_dbcsr_to_fm(mo_derivs(i)%matrix, fm_mo_derivs(i)%matrix) !fm->dbcsr
         ENDDO !fm->dbcsr

         smat => matrix_s(:, 1)
         CALL s2_restraint(mo_array, smat, fm_mo_derivs, energy%s2_restraint, &
                           dft_control%qs_control%s2_restraint_control, just_energy)

         DO i = 1, SIZE(mo_derivs, 1) !fm->dbcsr
            CALL copy_fm_to_dbcsr(fm_mo_derivs(i)%matrix, mo_derivs(i)%matrix) !fm->dbcsr
         ENDDO !fm->dbcsr
         DEALLOCATE (fm_mo_derivs) !fm->dbcsr

      ELSE
         energy%s2_restraint = 0.0_dp
      ENDIF
   END SUBROUTINE qs_ks_s2_restraint

END MODULE qs_ks_apply_restraints
